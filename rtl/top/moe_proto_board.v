`include "moe_params.vh"

// -----------------------------------------------------------------------------
// moe_proto_board
// -----------------------------------------------------------------------------
// ALINX AX7203B board level wrapper.
//
//   part  : xc7a200tfbg484-2
//   clock : 200 MHz differential oscillator on R4 / T4 (DIFF_SSTL15)
//   reset : rst_n on T6, active low (LVCMOS15)
//   led   : B13 / C13 / D14 / D15 (LVCMOS33), active LOW
//   uart  : on-board USB bridge, rx P20, tx N15 (LVCMOS33)
//
// Clock input style follows the factory led_test.v: a differential pair through
// IBUFDS, so the constraint file drives only sys_clk_p.
//
// -----------------------------------------------------------------------------
// V2 architecture: Ethernet-ready byte stream
// -----------------------------------------------------------------------------
// The board no longer self-starts from a ROM.  It is a passive device that waits
// for framed commands on a byte stream, and that byte stream is transport
// agnostic by design:
//
//     uart_rx  --\
//                 >-- mux --> moe_loader --> weight/activation ports, engine
//     jtag_axi --/             \--> reply --> mux --> uart_tx / AXI
//     (eth)   --/
//
// Two paths are wired today:
//
//   UART      : always present.  Slow (one byte per 1736 clocks at 115200) but it
//               needs no protocol stack and no extra clock, so it is the fallback
//               that always works.
//   JTAG-AXI  : compiled in only when WITH_JTAG_AXI is defined, because it needs
//               the jtag_axi IP (scripts/gen_jtag_axi.tcl).  It moves whole words
//               over the JTAG cable and needs no pins at all.
//
// Ethernet will attach at the same byte-stream mux once the MAC is written, which
// is the entire reason the loader was written against tdata/tvalid/tready rather
// than against a UART.
//
// Nothing here is initialised at configuration time: the weight and activation
// BRAMs come up empty and stay empty until a host loads them.
// -----------------------------------------------------------------------------
module moe_proto_board #(
    // A parameter rather than a localparam so a testbench that does not carry the
    // Ethernet sources can instantiate the core-only configuration.
    parameter WITH_ETH = 1
) (
    input         sys_clk_p,
    input         sys_clk_n,
    input         rst_n,
    input         uart_rx,
    output        uart_tx,
    output [3:0]  led,

    // ---- Ethernet port 1 (RGMII, 100 Mb) ----
    // Present unconditionally.  Leaving them out under `ifdef would change the
    // port list between configurations, and a port list change means a different
    // PINW/pin placement for everything else.
    input  [3:0]  rgmii_rxd,
    input         rgmii_rxctl,
    input         rgmii_rxc,
    output [3:0]  rgmii_txd,
    output        rgmii_txctl,
    output        rgmii_txc,
    output        phy_mdc,
    inout         phy_mdio,
    output        phy_rst_n
);

    // Ethernet control.  WITH_ETH=0 parks the port so the arbitration below stays
    // a straight three-input mux rather than needing a second code path.
    
    // ------------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------------
    //
    // THE BOARD OSCILLATOR IS 200 MHz, NOT 100 MHz.
    //
    // The factory design proves it: led_test.v counts 49_999_999 cycles for
    // "0.25 sec", which is only true at 200 MHz, and its own constraint file
    // says create_clock -period 5.000.
    //
    // An earlier build "closed timing" only because the build script overrode the
    // constraint to 10 ns - which changed the analysis target but not the
    // hardware.  The FPGA therefore ran the logic at twice the frequency it was
    // signed off for, and the checksum came out wrong.  RTL simulation and a
    // gate-level simulation of the routed netlist both produced the expected
    // value, which pinned the fault on timing rather than logic.
    //
    // The pipeline has since been reworked and 200 MHz now closes honestly.
    //
    //   DIV_BITS = 0  ->  /1  ->  200 MHz (current)
    //   DIV_BITS = 2  ->  /4  ->   50 MHz (the cautious first hardware run)
    //
    // Keep DIV_BITS and the XDC's create_generated_clock -divide_by in step;
    // build_moe.tcl checks them against each other and refuses to build if they
    // disagree.
    localparam DIV_BITS  = 0;

    localparam integer UART_CLK_FREQ  = 200_000_000;
    localparam integer UART_BAUD_RATE = 115_200;

    // LED blink, ~3 Hz at 200 MHz.
    localparam BLINK_BIT = 24;

    wire sys_clk_raw;
    wire clk_engine_raw;
    wire sys_clk;

    IBUFDS u_sys_clk_ibufds (
        .O  (sys_clk_raw),
        .I  (sys_clk_p),
        .IB (sys_clk_n)
    );

    generate
        if (DIV_BITS == 0) begin : g_no_div
            assign clk_engine_raw = sys_clk_raw;
        end else begin : g_div
            reg [DIV_BITS-1:0] div_cnt;
            reg                clk_div_q;

            always @(posedge sys_clk_raw or negedge rst_n) begin
                if (!rst_n) begin
                    div_cnt   <= {DIV_BITS{1'b0}};
                    clk_div_q <= 1'b0;
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                    if (div_cnt == 1'b1) clk_div_q <= ~clk_div_q;
                end
            end

            assign clk_engine_raw = clk_div_q;
        end
    endgenerate

    // A register driving a clock net needs a global buffer, otherwise the skew is
    // uncontrolled.  Naming it keeps the XDC's generated-clock reference
    // unambiguous.
    BUFG u_bufg_engine (
        .I (clk_engine_raw),
        .O (sys_clk)
    );

    // ------------------------------------------------------------------
    // UART
    // ------------------------------------------------------------------
    wire [7:0] u_rx_data;
    wire       u_rx_valid;
    wire       u_rx_ready;

    wire [7:0] u_tx_data;
    wire       u_tx_valid;
    wire       u_tx_ready;

    uart_rx #(
        .CLK_FREQ  (UART_CLK_FREQ),
        .BAUD_RATE (UART_BAUD_RATE)
    ) u_uart_rx (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .rx    (uart_rx),
        .data  (u_rx_data),
        .valid (u_rx_valid),
        .ready (u_rx_ready)
    );

    uart_tx #(
        .CLK_FREQ  (UART_CLK_FREQ),
        .BAUD_RATE (UART_BAUD_RATE)
    ) u_uart_tx (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .data  (u_tx_data),
        .valid (u_tx_valid),
        .ready (u_tx_ready),
        .tx    (uart_tx)
    );

    // ------------------------------------------------------------------
    // JTAG-to-AXI path (optional)
    // ------------------------------------------------------------------
    // Loader status, declared here because the AXI bridge below needs them.
    // They used to be declared further down, after the bridge, and the bridge's
    // status ports were left unconnected (.weights_ready() etc.).  That made the
    // bridge's STATUS *register* read back as all zeros forever, while the STATUS
    // *command* still worked - the command reply comes through the loader's own
    // byte FIFO, not through this register.  The result was a board where
    // "read STATUS at 0x04" always said healthy no matter what had gone wrong.
    wire        weights_ready, act_valid, busy;
    wire [7:0]  err_code;

    wire [7:0] a_tx_data;      // AXI master -> loader
    wire       a_tx_valid;
    wire       a_tx_ready;
    wire [7:0] a_rx_data;      // loader -> AXI master
    wire       a_rx_valid;
    wire       a_rx_ready;

    // Ethernet status wires.  Declared outside the WITH_JTAG_AXI block because
    // the LED logic below uses them whether or not the AXI bridge is compiled in;
    // leaving them inside the ifdef left them undeclared for the board testbench,
    // which cannot elaborate the jtag_axi IP and so never defines it.
    wire        eth_arp_found;
    wire [15:0] eth_rx_frames;
    wire [15:0] eth_udp_rx;
    wire [15:0] eth_tx_frames;
    wire [15:0] eth_rec_error;
    wire [15:0] eth_tx_done;
    wire        eth_probe_valid;
    wire [4:0]  eth_probe_addr;
    wire [15:0] eth_probe_id;

`ifdef WITH_JTAG_AXI
    // AXI4-Lite from the jtag_axi master
    wire [31:0] s_awaddr, s_wdata, s_araddr, s_rdata;
    wire [3:0]  s_wstrb;
    wire        s_awvalid, s_awready, s_wvalid, s_wready;
    wire [1:0]  s_bresp, s_rresp;
    wire        s_bvalid, s_bready, s_arvalid, s_arready, s_rvalid, s_rready;

    jtag_axi_0 u_jtag_axi (
        .aclk          (sys_clk),
        .aresetn       (rst_n),
        .m_axi_awaddr  (s_awaddr),
        .m_axi_awvalid (s_awvalid),
        .m_axi_awready (s_awready),
        .m_axi_awprot  (),
        .m_axi_wdata   (s_wdata),
        .m_axi_wstrb   (s_wstrb),
        .m_axi_wvalid  (s_wvalid),
        .m_axi_wready  (s_wready),
        .m_axi_bresp   (s_bresp),
        .m_axi_bvalid  (s_bvalid),
        .m_axi_bready  (s_bready),
        .m_axi_araddr  (s_araddr),
        .m_axi_arvalid (s_arvalid),
        .m_axi_arready (s_arready),
        .m_axi_arprot  (),
        .m_axi_rdata   (s_rdata),
        .m_axi_rresp   (s_rresp),
        .m_axi_rvalid  (s_rvalid),
        .m_axi_rready  (s_rready)
    );


      // STATUS bytes 0..3, most significant first:
      //   [31]    arp_found     (received an ARP reply addressed to us)
      //   [23:16] tx_frames     (frames the MAC transmitted)
      //   [15:8]  udp_rx        (datagrams that passed every check)
      //   [7:0]   rx_frames     (carrier arrivals)
      wire [31:0] eth_dbg = { eth_arp_found,
                              eth_tx_frames[7:0],
                              eth_udp_rx[7:0],
                              eth_rx_frames[7:0] };

      // 0x18 = {probe_valid, 3'd0, probe_addr[4:0], 7'd0, probe_id[15:0]}
      wire        eth_arp_resolved;
      wire [15:0] ram_wr_cnt;
      wire [10:0] ram_wr_addr;
      wire [7:0]  ram_wr_data;
      wire [5:0]  ld_cap_raddr;
      wire [7:0]  ld_cap_rdata;
      wire [15:0] ld_cap_count;
      wire [15:0] ld_cap_len;
      wire [15:0] ld_cap_pay;
      wire [15:0] eth_mac_err;
      wire [15:0] eth_csum_err;
      wire [15:0] eth_addr_err;
      wire [10:0] snf_raddr;
      wire [15:0] snf_rdata;
      wire [10:0] snf_wr_ptr;
      wire [15:0] snf_count;

      wire [31:0] eth_dbg4 = { {7'd0, eth_arp_resolved},
                               eth_mac_err[7:0],
                               eth_csum_err[7:0],
                               eth_addr_err[7:0] };

      wire [4:0]  eth_idly_tap;
      wire [4:0]  eth_idly_tap_out;
      wire        eth_idly_ld;

      wire [31:0] eth_dbg3 = { eth_probe_valid, 3'd0,
                               eth_probe_addr,
                               7'd0,
                               eth_probe_id };

      wire [31:0] eth_dbg2 = { eth_rec_error[7:0],
                               eth_tx_done[7:0],
                               8'd0,
                               8'd0 };


    axil_loader_bridge u_axil_bridge (
        .clk (sys_clk), .rst_n (rst_n),
        .s_axi_awaddr(s_awaddr), .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
        .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
        .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
        .s_axi_araddr(s_araddr), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
        .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),
        .s_axis_tdata(a_tx_data), .s_axis_tvalid(a_tx_valid), .s_axis_tready(a_tx_ready),
        .m_axis_tdata(a_rx_data), .m_axis_tvalid(a_rx_valid), .m_axis_tready(a_rx_ready),
        .weights_ready(weights_ready), .act_valid(act_valid),
        .busy(busy), .err_code (err_code),
        .eth_dbg(eth_dbg), .eth_dbg2(eth_dbg2), .eth_dbg3(eth_dbg3),
        .idly_tap(eth_idly_tap), .idly_ld(eth_idly_ld),
        .idly_tap_out(eth_idly_tap_out),
        .eth_dbg4(eth_dbg4),
        .snf_rdata(snf_rdata), .snf_wr_ptr(snf_wr_ptr),
        .snf_count(snf_count), .snf_raddr(snf_raddr),
        .ld_cap_rdata(ld_cap_rdata), .ld_cap_count(ld_cap_count),
        .ld_cap_len(ld_cap_len), .ld_cap_pay(ld_cap_pay),
        .ld_cap_raddr(ld_cap_raddr),
        .ram_wr_cnt(ram_wr_cnt), .ram_wr_addr(ram_wr_addr), .ram_wr_data(ram_wr_data)
    );
`else
    // No JTAG-AXI in this build: park the port so the mux below is unconditional.
    assign a_tx_data  = 8'd0;
    assign a_tx_valid = 1'b0;
    assign a_rx_ready = 1'b0;
`endif

    // ------------------------------------------------------------------
    // Byte-stream arbitration
    // ------------------------------------------------------------------
    // AXI wins ties: a JTAG transaction is already committed by the time it
    // reaches us, whereas a UART byte can be held indefinitely by its own
    // handshake.
    wire        ld_valid;
    wire [7:0]  ld_data;
    wire        ld_ready;

    // Three sources now.  Priority is fixed and deliberate:
    //   1. JTAG-AXI   a transaction is already committed when it arrives, so it
    //                 cannot be held off without stalling the debug cable
    //   2. Ethernet   the stack has a small buffer and drops rather than stalls,
    //                 so it needs to win over anything that can be retried
    //   3. UART       can be held indefinitely by its own handshake; it is the
    //                 fallback transport
    wire        e_tx_valid;
    wire [7:0]  e_tx_data;
    wire        e_tx_ready;
    wire        e_rx_valid;
    wire [7:0]  e_rx_data;
    wire        e_rx_ready;

    assign ld_valid = a_tx_valid | e_tx_valid | u_rx_valid;
    assign ld_data  = a_tx_valid ? a_tx_data :
                      e_tx_valid ? e_tx_data : u_rx_data;

    assign a_tx_ready = ld_ready &&  a_tx_valid;
    assign e_tx_ready = ld_ready && !a_tx_valid &&  e_tx_valid;
    assign u_rx_ready = ld_ready && !a_tx_valid && !e_tx_valid;

    // Replies go back to whoever spoke last, so a UART host and a JTAG host can
    // both interrogate the same board without stealing each other's data.
    // 0 = UART, 1 = JTAG-AXI, 2 = Ethernet.  Latched on every byte the loader
    // accepts, so the reply follows the transport that sent the command.
    reg [1:0] reply_src;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) reply_src <= 2'd0;
        else if (ld_valid && ld_ready)
            reply_src <= a_tx_valid ? 2'd1 : (e_tx_valid ? 2'd2 : 2'd0);
    end

    wire        ld_mvalid;
    wire [7:0]  ld_mdata;
    wire        ld_mready;

    assign ld_mready  = (reply_src == 2'd1) ? a_rx_ready :
                        (reply_src == 2'd2) ? e_rx_ready : u_tx_ready;
    assign a_rx_valid = ld_mvalid & (reply_src == 2'd1);
    assign a_rx_data  = ld_mdata;
    assign e_rx_valid = ld_mvalid & (reply_src == 2'd2);
    assign e_rx_data  = ld_mdata;
    assign u_tx_valid = ld_mvalid & (reply_src == 2'd0);
    assign u_tx_data  = ld_mdata;

    // ------------------------------------------------------------------
    // Ethernet transport
    // ------------------------------------------------------------------
    wire [7:0] e_ld_tdata;
    wire       e_ld_tvalid;
    wire       e_ld_tlast;
    wire [7:0] e_ld_rdata;
    wire       e_ld_rvalid;
    wire       e_ld_rready;
    wire       e_ld_rlast;
    wire       eth_cfg_done;
    wire [2:0] eth_mdio_step;
    wire [3:0] eth_event;

    generate if (WITH_ETH) begin : g_eth
        eth_top #(
            .LOCAL_MAC  (48'h020000000001),
            .LOCAL_IP   (32'hC0A80806),      // 192.168.8.6
            .LOCAL_PORT (16'd1234)
        ) u_eth (
            .clk            (sys_clk),
            .rst_n          (rst_n),
            .rgmii_rxd      (rgmii_rxd),
            .rgmii_rxctl    (rgmii_rxctl),
            .rgmii_rxc      (rgmii_rxc),
            .rgmii_txd      (rgmii_txd),
            .rgmii_txctl    (rgmii_txctl),
            .rgmii_txc      (rgmii_txc),
            .phy_mdc        (phy_mdc),
            .phy_mdio       (phy_mdio),
            .phy_rst_n      (phy_rst_n),
            .ld_tdata       (e_ld_tdata),
            .ld_tvalid      (e_ld_tvalid),
            .ld_tready      (e_tx_ready),
            .ld_tlast       (e_ld_tlast),
            .ld_rdata       (e_ld_rdata),
            .ld_rvalid      (e_ld_rvalid),
            .ld_rready      (e_rx_ready),
            .ld_rlast       (e_ld_rlast),
            .phy_cfg_done   (eth_cfg_done),
            .mdio_step      (eth_mdio_step),
            .dbg_arp_found  (eth_arp_found),
              .dbg_rx_frames  (eth_rx_frames),
              .dbg_udp_rx     (eth_udp_rx),
              .dbg_tx_frames  (eth_tx_frames),
              .dbg_rec_error  (eth_rec_error),
              .dbg_tx_done    (eth_tx_done),
              .probe_valid    (eth_probe_valid),
              .probe_addr     (eth_probe_addr),
              .probe_id       (eth_probe_id),
              .idly_tap       (eth_idly_tap),
              .idly_ld        (eth_idly_ld),
              .idly_tap_out   (eth_idly_tap_out),
              .arp_resolved   (eth_arp_resolved),
              .dbg_mac_err    (eth_mac_err),
              .dbg_ip_csum_err(eth_csum_err),
              .dbg_ip_addr_err(eth_addr_err),
              .snf_raddr      (snf_raddr),
              .snf_rdata      (snf_rdata),
              .snf_wr_ptr     (snf_wr_ptr),
              .snf_count      (snf_count),
              .ld_cap_raddr   (ld_cap_raddr),
              .ld_cap_rdata   (ld_cap_rdata),
              .ld_cap_count   (ld_cap_count),
              .ld_cap_len     (ld_cap_len),
              .ld_cap_pay     (ld_cap_pay),
              .ram_wr_cnt     (ram_wr_cnt),
              .ram_wr_addr    (ram_wr_addr),
              .ram_wr_data    (ram_wr_data)
        );
    end else begin : g_no_eth
        assign e_ld_tdata  = 8'd0;
        assign e_ld_tvalid = 1'b0;
        assign e_ld_tlast  = 1'b0;
        assign e_ld_rlast  = 1'b0;
        assign eth_cfg_done = 1'b0;
        assign eth_arp_found = 1'b0;
          assign eth_rx_frames = 16'd0;
          assign eth_udp_rx    = 16'd0;
          assign eth_tx_frames = 16'd0;
          assign eth_rec_error = 16'd0;
          assign eth_tx_done   = 16'd0;
          assign eth_probe_valid = 1'b0;
          assign eth_probe_addr  = 5'd0;
          assign eth_probe_id    = 16'd0;
          assign eth_mac_err     = 16'd0;
          assign eth_arp_resolved = 1'b0;
          assign eth_csum_err    = 16'd0;
          assign eth_addr_err    = 16'd0;
          assign snf_rdata       = 16'd0;
          assign snf_wr_ptr      = 11'd0;
          assign snf_count       = 16'd0;
          assign ld_cap_rdata    = 8'd0;
          assign ld_cap_count    = 16'd0;
          assign ld_cap_len      = 16'd0;
          assign ld_cap_pay      = 16'd0;
          assign ram_wr_cnt      = 16'd0;
          assign ram_wr_addr     = 11'd0;
          assign ram_wr_data     = 8'd0;
        assign rgmii_txd    = 4'd0;
        assign rgmii_txctl  = 1'b0;
        assign rgmii_txc    = 1'b0;
        assign phy_mdc      = 1'b0;
        assign phy_mdio     = 1'bZ;
        assign phy_rst_n    = 1'b1;
    end
    endgenerate

    assign e_tx_valid = e_ld_tvalid;
    assign e_tx_data  = e_ld_tdata;
    assign e_rx_valid = e_ld_rvalid;
    assign e_rx_data  = e_ld_rdata;
    assign e_ld_rready = e_rx_ready;

    // ------------------------------------------------------------------
    // Loader
    // ------------------------------------------------------------------
    wire                       w_wr_en;
    wire [1:0]                 w_wr_region;
    wire [`H_ADDR_W-1:0]       w_wr_addr;
    wire [`REGION_WCODE_W-1:0] w_wr_data;

    wire                       a_wr_en;
    wire [`H_ADDR_W-1:0]       a_wr_addr;
    wire [`ACT_W-1:0]          a_wr_data;

    wire        gemv_start, gemv_busy, gemv_done;
    wire        rd_start;
    wire [`E_ADDR_W-1:0] rd_start_lane;
    wire        rd_pause, rd_valid, rd_busy;
    wire [`E_ADDR_W-1:0] rd_lane;
    wire [1:0]  rd_byte;
    wire [7:0]  rd_data;

    // Weight readback: narrow only.  The 256-bit row is selected and serialised
    // inside gemv_engine so it never has to cross the die to reach the loader.
    wire                    rb_start;
    wire [1:0]              rb_region;
    wire [`H_ADDR_W-1:0]    rb_addr;
    wire [15:0]             rb_nrows;
    wire                    rb_byte_ready;
    wire [7:0]              rb_byte_out;
    wire                    rb_byte_valid;
    wire                    rb_done;

    // weights_ready / act_valid / busy / err_code are declared above, next to the
    // AXI bridge that also consumes them.
    wire [31:0] result_checksum;

    moe_loader u_loader (
        .clk (sys_clk), .rst_n (rst_n),
        .s_axis_tdata (ld_data), .s_axis_tvalid (ld_valid),
        .s_axis_tready(ld_ready), .s_axis_tlast (1'b0),
        .m_axis_tdata (ld_mdata), .m_axis_tvalid(ld_mvalid),
        .m_axis_tready(ld_mready), .m_axis_tlast(),
        .w_wr_en(w_wr_en), .w_wr_region(w_wr_region),
        .w_wr_addr(w_wr_addr), .w_wr_data(w_wr_data),
        .a_wr_en(a_wr_en), .a_wr_addr(a_wr_addr), .a_wr_data(a_wr_data),
        .gemv_start(gemv_start), .gemv_busy(gemv_busy), .gemv_done(gemv_done),
        .rd_start(rd_start), .rd_start_lane(rd_start_lane), .rd_pause(rd_pause),
        .rd_valid(rd_valid), .rd_lane(rd_lane), .rd_byte(rd_byte),
        .rd_data(rd_data), .rd_busy(rd_busy),
        .rb_start(rb_start), .rb_region(rb_region), .rb_addr(rb_addr),
        .rb_nrows(rb_nrows), .rb_byte_ready(rb_byte_ready),
        .rb_byte_out(rb_byte_out), .rb_byte_valid(rb_byte_valid), .rb_done(rb_done),
        .weights_ready(weights_ready), .act_valid(act_valid),
        .busy(busy), .eth_dbg (eth_dbg), .err_code (err_code)
    );

    // ------------------------------------------------------------------
    // Engine
    // ------------------------------------------------------------------
    moe_proto_top u_moe_proto_top (
        .clk            (sys_clk),
        .rst_n          (rst_n),
        .start          (gemv_start),
        .busy           (gemv_busy),
        .done           (gemv_done),
        .w_wr_en        (w_wr_en),
        .w_wr_region    (w_wr_region),
        .w_wr_addr      (w_wr_addr),
        .w_wr_data      (w_wr_data),
        .act_wr_en      (a_wr_en),
        .act_wr_addr    (a_wr_addr),
        .act_wr_data    (a_wr_data),
        .rd_start       (rd_start),
        .rd_start_lane  (rd_start_lane),
        .rd_pause       (rd_pause),
        .rd_valid       (rd_valid),
        .rd_lane        (rd_lane),
        .rd_byte        (rd_byte),
        .rd_data        (rd_data),
        .rd_busy        (rd_busy),
        .rb_start       (rb_start),
        .rb_region      (rb_region),
        .rb_addr        (rb_addr),
        .rb_nrows       (rb_nrows),
        .rb_byte_ready  (rb_byte_ready),
        .rb_byte_out    (rb_byte_out),
        .rb_byte_valid  (rb_byte_valid),
        .rb_done        (rb_done),
        .result_checksum(result_checksum)
    );

    // ------------------------------------------------------------------
    // Status LEDs, active LOW
    // ------------------------------------------------------------------
    //   LED1  lit when weights are loaded
    //   LED2  lit when the activation vector is loaded
    //   LED3  lit while a GEMV is running
    //   LED4  heartbeat: blinks while healthy, solid lit on a sticky error
    //
    // The heartbeat matters: without it a correctly configured idle board and an
    // unconfigured one both show all four LEDs dark, which is the same ambiguity
    // that made the earlier PASS/FAIL bring-up confusing.
    //
    // Deliberately not a PASS/FAIL verdict any more: with runtime-loadable weights
    // there is no single golden checksum, so the host is the judge and the LEDs
    // only report state.
    reg [24:0] blink_cnt;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) blink_cnt <= 25'd0;
        else        blink_cnt <= blink_cnt + 25'd1;
    end

    wire blink_phase = blink_cnt[BLINK_BIT];
    // Two rates off the same counter: ~1.6 Hz and ~0.4 Hz at 200 MHz.
    localparam integer BLINK_BIT_FAST = 22;
    localparam integer BLINK_BIT_SLOW = 24;

    // LED plan for the Ethernet bring-up.
    //
    // LED4 is a HEARTBEAT that never stops, so "all four LEDs dark" unambiguously
    // means the design is not running.  The previous version made LED4 blink only
    // when eth_cfg_done was high, and eth_cfg_done is a ONE-CYCLE pulse from the
    // MDIO state machine - so LED4 could never light, and a board that was running
    // perfectly looked identical to a dead one.
    //
    // The blink RATE now carries the status:
    //   fast blink (bit BLINK_BIT_FAST) = MDIO sequence completed, PHY configured
    //   slow blink (bit BLINK_BIT_SLOW) = still in reset/wait, not configured yet
    //
    // LED1..3 are unchanged: lit when weights_ready / act_valid / busy.
    wire blink_fast = blink_cnt[BLINK_BIT_FAST];
    wire blink_slow = blink_cnt[BLINK_BIT_SLOW];
    wire mdio_ok    = (eth_mdio_step == 3'd5);

    assign led[0] = ~weights_ready;
    assign led[1] = ~act_valid;
    assign led[2] = ~busy;
    // LED4 reports the receive path, which is the question this design exists to
// answer.  Three states, distinguishable by eye:
//   fast blink  an ARP reply was generated  -> the whole chain works
    //   slow blink  frames are arriving but no ARP reply -> wire is alive, frames rejected
    //   dark        nothing has ever arrived    -> physical or PHY problem
    assign led[3] = ~( eth_arp_found            ? blink_fast :
                       (eth_rx_frames != 16'd0) ? blink_slow : 1'b0 );

    wire unused_mdio_step = |eth_mdio_step;
    wire unused_cfg_done  = eth_cfg_done;

    wire unused_checksum = ^result_checksum;

endmodule