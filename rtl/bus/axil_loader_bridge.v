`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// axil_loader_bridge - AXI4-Lite to byte-stream bridge
// -----------------------------------------------------------------------------
// Lets a memory-mapped AXI master drive the byte-stream loader.  The intended
// master is Xilinx's jtag_axi IP, which turns JTAG transactions issued by
// Vivado's Hardware Manager into AXI reads and writes.  That gives a debug path
// needing no pins, no extra clock domain and no protocol stack: when the
// Ethernet bring-up is going badly at 2 a.m., this is how a value still gets
// into the machine and a value back out.
//
// The same bridge fits any other memory-mapped master - MicroBlaze, a PCIe BAR, an
// AXI DMA - so the loader never has to know who is talking to it.
//
// Register map (word aligned, 32-bit):
//
//   0x00  W  TXDATA   write 32 bits -> four bytes pushed LSB-first into the
//                     loader's AXI-Stream sink.  Back-pressured until all four
//                     are accepted, so a word cannot be overwritten mid-shift.
//   0x04  R  STATUS   [0] weights_ready  [1] act_valid  [2] busy  [15:8] err_code
//   0x08  R  RXDATA   pops four bytes from the reply FIFO, LSB first, and
//                     returns them.  Reads as 0 when fewer than four bytes are
//                     available, so poll RXCOUNT first.
//   0x0C  R  RXCOUNT  [15:0] bytes available in the reply FIFO
//
// Reading RXDATA has a side effect.  That is unusual for AXI but it is the
// normal shape for a FIFO pop register, and the AXI read channel only pops once
// per accepted AR, so a retried transaction cannot consume twice.
//
// There are two reply FIFOs on purpose: the loader's keeps the readout (one byte
// every 6 clocks) independent of the transport, and this one keeps the AXI read
// channel (which stalls for many clocks between transactions) from stalling the
// loader.  When this FIFO fills, m_axis_tready drops and the readout pauses.
// -----------------------------------------------------------------------------
module axil_loader_bridge #(
    parameter RX_AW = 5                        // reply FIFO depth = 1 << RX_AW
)(
    input  clk,
    input  rst_n,

    // AXI4-Lite slave
    input  [31:0] s_axi_awaddr,
    input         s_axi_awvalid,
    output        s_axi_awready,
    input  [31:0] s_axi_wdata,
    input  [3:0]  s_axi_wstrb,
    input         s_axi_wvalid,
    output        s_axi_wready,
    output [1:0]  s_axi_bresp,
    output        s_axi_bvalid,
    input         s_axi_bready,

    input  [31:0] s_axi_araddr,
    input         s_axi_arvalid,
    output        s_axi_arready,
    output [31:0] s_axi_rdata,
    output [1:0]  s_axi_rresp,
    output        s_axi_rvalid,
    input         s_axi_rready,

    // byte stream to the loader
    output wire [7:0] s_axis_tdata,
    output reg       s_axis_tvalid,
    input            s_axis_tready,

    // byte stream from the loader
    input      [7:0] m_axis_tdata,
    input            m_axis_tvalid,
    output           m_axis_tready,

    // loader status
    input            weights_ready,
    input            act_valid,
    input            busy,
    // Ethernet diagnostics, one register each.  Four numbers per word, most
    // significant byte first, so a single AXI read describes the whole chain.
    input      [31:0] eth_dbg,
    input      [31:0] eth_dbg2,
    input      [31:0] eth_dbg3,

    // Runtime RGMII receive delay tap, so the sampling point can be swept from
    // JTAG instead of being compiled in.  Write 0x10 with [4:0] = tap.
    input      [31:0] eth_dbg4,       // graded receive errors
    input      [7:0]  ld_cap_rdata,
    input      [15:0] ld_cap_count,
    input      [15:0] ld_cap_len,
    input      [15:0] ld_cap_pay,
    input      [15:0] ram_wr_cnt,
    input      [10:0] ram_wr_addr,
    input      [7:0]  ram_wr_data,
    output reg [5:0]  ld_cap_raddr,

    input      [15:0] snf_rdata,
    input      [10:0] snf_wr_ptr,
    input      [15:0] snf_count,
    output reg [10:0] snf_raddr,
    input      [4:0]  idly_tap_out,   // CNTVALUEOUT readback

    output reg [4:0]  idly_tap = 5'd31,   // 31 is the value measured on hardware;
                                          // the vendor's 10 does not work on this board
    output            idly_ld,

    input      [7:0] err_code
);

    localparam RX_D = (1 << RX_AW);

    // ==================================================================
    // Write channel
    // ==================================================================
    reg        aw_held, w_held;
    reg [31:0] awaddr_r, wdata_r;
    reg [5:0]  idly_ld_cnt;
    assign idly_ld = (idly_ld_cnt != 6'd0);
    reg [1:0]  bresp_r;
    reg        bvalid_r;

    reg [31:0] tx_word;
reg [1:0]  tx_idx;
reg        tx_busy;

// The byte MUST be selected combinationally from tx_idx.
//
// As a registered assignment inside the clocked block below it sampled the OLD
// tx_idx in the same cycle that incremented it, so a word left as
// [b0, b0, b1, b2] - first byte twice, last byte never - and every frame arrived
// one byte out of step.  The loader correctly rejected those as ERR_BAD_CMD.
assign s_axis_tdata  = tx_word[tx_idx*8 +: 8];

    assign s_axi_awready = !aw_held && !tx_busy && !bvalid_r;
    assign s_axi_wready  = !w_held  && !tx_busy && !bvalid_r;
    assign s_axi_bvalid  = bvalid_r;
    assign s_axi_bresp   = bresp_r;

    // ==================================================================
    // Reply FIFO
    // ==================================================================
    reg [7:0]        rx_fifo [0:RX_D-1];
    reg [RX_AW-1:0]  rx_wp, rx_rp;
    reg [RX_AW:0]    rx_cnt;

    wire rx_full = (rx_cnt == RX_D);
    wire rx_push = m_axis_tvalid && !rx_full;

    assign m_axis_tready = !rx_full;

    // ==================================================================
    // Read channel
    // ==================================================================
    reg        ar_held;
    reg [31:0] araddr_r;
    reg [31:0] rdata_r;
    reg        rvalid_r;

    assign s_axi_arready = !ar_held && !rvalid_r;
    assign s_axi_rdata   = rdata_r;
    assign s_axi_rvalid  = rvalid_r;
    assign s_axi_rresp   = 2'b00;

    wire [3:0] rsel     = araddr_r[5:2];
    wire       ar_take  = ar_held && !rvalid_r;
    wire       pop_now  = ar_take && (rsel == 4'd2) && (rx_cnt >= 4);

    wire [7:0] rx_b0 = rx_fifo[rx_rp];
    wire [7:0] rx_b1 = rx_fifo[(rx_rp + 1'b1) & (RX_D-1)];
    wire [7:0] rx_b2 = rx_fifo[(rx_rp + 2'd2) & (RX_D-1)];
    wire [7:0] rx_b3 = rx_fifo[(rx_rp + 2'd3) & (RX_D-1)];

    reg [31:0] rdata_sel;
    always @* begin
        case (rsel)
  4'd1:    rdata_sel = {16'd0, err_code, 5'd0, busy, act_valid, weights_ready};
  4'd2:    rdata_sel = pop_now ? {rx_b3, rx_b2, rx_b1, rx_b0} : 32'd0;
             4'd3:    rdata_sel = {16'd0, rx_cnt};
            // 0x10 Ethernet: {arp_found, tx_frames[7:0], udp_rx[7:0], rx_frames[7:0]}
             4'd4:    rdata_sel = eth_dbg;
            // 0x14 Ethernet: {rec_error[7:0], tx_done[7:0], udp_tx_done[7:0], 8'd0}
             4'd5:    rdata_sel = eth_dbg2;
            // 0x18 PHY probe: {valid, addr[4:0], id[15:0]}
             4'd6:    rdata_sel = eth_dbg3;
            // 0x20 graded errors: {8'd0, mac_err[7:0], ip_csum_err[7:0], ip_addr_err[7:0]}
            4'd8:    rdata_sel = eth_dbg4;
            // 0x24 capture status: {5'd0, wr_ptr[10:0], count[15:0]}
            4'd9:    rdata_sel = {5'd0, snf_wr_ptr, snf_count};
            // 0x28 captured entry at the address written to 0x14
            4'd10:   rdata_sel = {16'd0, snf_rdata};
            // 0x2C: the tap the IDELAY primitive actually holds
            4'd11:   rdata_sel = {27'd0, idly_tap_out};
            // 0x30 write: select which captured loader byte 0x34 returns
            // 0x34 read : that byte
            // 0x38 read : {payload_len[15:0], bytes_forwarded[15:0]}
            // 0x3C read : {16'd0, udp_rec_data_length[15:0]}
            4'd7:    rdata_sel = {5'd0, ram_wr_addr, ram_wr_cnt};
            4'd12:   rdata_sel = {24'd0, ld_cap_rdata};
            4'd13:   rdata_sel = {24'd0, ram_wr_data};
            4'd14:   rdata_sel = {ld_cap_pay, ld_cap_count};
            4'd15:   rdata_sel = {16'd0, ld_cap_len};
            default: rdata_sel = 32'd0;
        endcase
    end

    // ==================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_held       <= 1'b0;
            w_held        <= 1'b0;
            awaddr_r      <= 32'd0;
            wdata_r       <= 32'd0;
            bresp_r       <= 2'b00;
            bvalid_r      <= 1'b0;
            tx_word       <= 32'd0;
            tx_idx        <= 2'd0;
            tx_busy       <= 1'b0;
            s_axis_tvalid <= 1'b0;
            ar_held       <= 1'b0;
            araddr_r      <= 32'd0;
            rdata_r       <= 32'd0;
            rvalid_r      <= 1'b0;
            rx_wp         <= {RX_AW{1'b0}};
            rx_rp         <= {RX_AW{1'b0}};
            rx_cnt        <= {(RX_AW+1){1'b0}};
        end else begin
            // ---------------- write side --------------------------
            if (s_axi_awvalid && s_axi_awready) begin
                aw_held  <= 1'b1;
                awaddr_r <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_held  <= 1'b1;
                wdata_r <= s_axi_wdata;
            end

            if (aw_held && w_held && !tx_busy) begin
                aw_held  <= 1'b0;
                w_held   <= 1'b0;
                bvalid_r <= 1'b1;
                bresp_r  <= 2'b00;
                if (awaddr_r[5:2] == 4'd4) begin
                    // 0x10 write: set the RGMII receive delay tap.
                    // idly_ld stays high for 32 cycles (~160 ns).  A one-cycle
                    // pulse at 200 MHz is 5 ns, shorter than the 8 ns period of
                    // the 125 MHz clock the IDELAYE2 is clocked by, so the load
                    // could be missed entirely - which is exactly why the first
                    // tap sweep showed no change at any value.
                    idly_tap     <= wdata_r[4:0];
                    idly_ld_cnt  <= 6'd32;
                end else if (awaddr_r[5:2] == 4'd5) begin
                    // 0x14 write: select which capture entry 0x28 returns
                    snf_raddr <= wdata_r[10:0];
                end else if (awaddr_r[5:2] == 4'd12) begin
                    // 0x30 write: select which loader-feed byte 0x34 returns
                    ld_cap_raddr <= wdata_r[5:0];
                end else if (awaddr_r[3:2] == 2'd0) begin
                    tx_word <= wdata_r;
                    tx_idx  <= 2'd0;
                    tx_busy <= 1'b1;
                end
                // Writes to the read-only registers are accepted and ignored so
                // a stray poke cannot wedge the write channel.
            end
            if (bvalid_r && s_axi_bready) bvalid_r <= 1'b0;

            // ---------------- byte push ---------------------------
            // s_axis_tdata is driven combinationally from tx_idx (see the assign above).
            // As a register assignment here it sampled the old tx_idx in the same
            // cycle that incremented it, so each word left as [b0, b0, b1, b2].
            if (tx_busy) begin
                s_axis_tvalid <= 1'b1;
                if (s_axis_tvalid && s_axis_tready) begin
                    if (tx_idx == 2'd3) begin
                        tx_busy       <= 1'b0;
                        s_axis_tvalid <= 1'b0;
                    end else begin
                        tx_idx <= tx_idx + 2'd1;
                    end
                end
            end else begin
                s_axis_tvalid <= 1'b0;
            end

            // ---------------- read side ---------------------------
            if (s_axi_arvalid && s_axi_arready) begin
                ar_held  <= 1'b1;
                araddr_r <= s_axi_araddr;
            end
            if (ar_take) begin
                ar_held  <= 1'b0;
                rdata_r  <= rdata_sel;
                rvalid_r <= 1'b1;
            end
            if (rvalid_r && s_axi_rready) rvalid_r <= 1'b0;

            // ---------------- reply FIFO --------------------------
            if (rx_push) begin
                rx_fifo[rx_wp] <= m_axis_tdata;
                rx_wp <= rx_wp + 1'b1;
            end
            if (pop_now) begin
                // 3'd4, not 2'd4.  A 2-bit literal cannot represent 4: it
                // truncates to 0, so rx_rp never moved and every RXDATA read
                // returned the same four bytes.  The tell was rx_cnt counting
                // down correctly while rx_rp stayed pinned at 0, which read at
                // first like a stale AXI read channel.
                // Same trap as localparam [10:0] SETTLE_CYCLES = 11'd2048 earlier.
                rx_rp <= rx_rp + 3'd4;
            end

            // Single occupancy update, so a simultaneous push and pop is
            // counted correctly.  Two separate case arms here would silently
            // drop the -4 whenever a push landed in the same cycle.
            rx_cnt <= rx_cnt + (rx_push ? 1'b1 : 1'b0) - (pop_now ? 3'd4 : 3'd0);
        end
    end

    wire unused_wstrb = |s_axi_wstrb;

endmodule