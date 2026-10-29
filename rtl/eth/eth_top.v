`include "moe_params.vh"

// -----------------------------------------------------------------------------
// eth_top  -  gigabit RGMII on top of the vendor MAC
// -----------------------------------------------------------------------------
// The hand-written protocol stack is replaced by the vendor's `mac_top` from the
// ethernet_test demo.  The reason is diagnostic as much as functional:
//
//   The vendor MAC validates every received frame at three levels -
//     preamble must be exactly 55 55 55 55 55 55 55 D5   (mac_rx.v)
//     ethertype must be 0x0800 or 0x0806                  (mac_rx.v REC_IDENTIFY)
//     the FCS must match                                  (mac_rx.v REC_CRC)
//   and any failure goes to REC_ERROR.
//
//   The hand-written receiver checked none of that, so "no frame arrived",
//   "a frame arrived corrupted" and "a frame arrived but was not for us" were
//   indistinguishable - which is exactly the question that could not be answered
//   on the board.
//
// ARP needs no transmit logic here: mac_top answers ARP requests internally
// (arp_reply_req/ack between mac_rx_top and mac_tx_top) as long as
// source_mac_addr and source_ip_addr are set.  The transmit shim below is only
// for UDP replies to the host.
//
// Clocking
//   util_gmii_to_rgmii derives its transmit clock from the PHY receive clock -
//       assign gmii_tx_clk = gmii_rx_clk;
//   so the whole wire side is one 125 MHz domain.  Only the loader interface
//   crosses to the 200 MHz fabric, through the two eth_async_fifo instances.
// -----------------------------------------------------------------------------
module eth_top #(
    parameter [47:0]  LOCAL_MAC  = 48'h02_00_00_00_00_01,
    parameter [31:0]  LOCAL_IP   = 32'hC0A80806,     // 192.168.8.6
    // The peer whose MAC has to be resolved before anything can be transmitted.
    // The vendor's transmit path does NOT stall when the ARP cache is empty - it
    // just sends with a broadcast destination MAC - so the cache has to be filled
    // before a reply is needed, which is what the ARP request generator below is
    // for.  192.168.8.8 is the host that pings this board.
    parameter [31:0]  PEER_IP    = 32'hC0A80808,     // 192.168.8.8
    parameter [15:0]  LOCAL_PORT = 16'd1234,
    parameter [7:0]   LOCAL_TTL  = 8'd64
)(
    input             clk,           // 200 MHz fabric
    input             rst_n,

    input      [3:0]  rgmii_rxd,
    input             rgmii_rxctl,
    input             rgmii_rxc,
    output     [3:0]  rgmii_txd,
    output            rgmii_txctl,
    output            rgmii_txc,

    output            phy_mdc,
    inout             phy_mdio,
    output            phy_rst_n,

    output     [7:0]  ld_tdata,
    output            ld_tvalid,
    input             ld_tready,
    output            ld_tlast,

    input      [7:0]  ld_rdata,
    input             ld_rvalid,
    output            ld_rready,
    input             ld_rlast,

    output            phy_cfg_done,
output     [2:0]  mdio_step,      // 0 while sweeping, 5 once the probe finished

    // ---- PHY probe results ----
    output            probe_valid,    // 1 = some MDIO address answered
    output     [4:0]  probe_addr,     // which address answered
    output     [15:0] probe_id,       // PHY identifier register 2

    // 0 while the ARP cache holds no entry for PEER_IP.  Goes to 1 once the peer
    // has answered, which is the precondition for any reply reaching it.
    output            arp_resolved,

    // RGMII receive delay tap, set from the AXI bridge so the sampling point can
    // be swept on hardware instead of guessed in RTL.
    input      [4:0]  idly_tap,
    input             idly_ld,
    output     [4:0]  idly_tap_out,   // IDELAY CNTVALUEOUT, proves the tap loaded

    // ---- graded receive errors: which layer rejected the frame ----
    output reg [15:0] dbg_mac_err,      // preamble / ethertype / FCS
    output reg [15:0] dbg_ip_csum_err,  // IP header checksum
    output reg [15:0] dbg_ip_addr_err,  // data fine, addressed elsewhere

    // ---- raw capture of the received byte stream ----
    // ---- diagnostic capture of the bytes handed to the loader ----
    // The wire capture proves the frames are valid, but not what the shim
    // actually forwards.  This records the last 64 bytes that crossed into the
    // loader, plus the length the shim derived, so the two can be compared.
    input      [5:0]  ld_cap_raddr,
    output     [7:0]  ld_cap_rdata,
    output     [15:0] ld_cap_count,     // total bytes forwarded
    output     [15:0] ld_cap_len,       // udp_rec_data_length at packet start
    output     [15:0] ld_cap_pay,
    // Datagrams that arrived while the previous one was still being forwarded.
    // udp_rx does not wait for the consumer, so such a datagram is lost and its
    // RAM is overwritten mid-read - nothing here can prevent it, but silence is
    // worse than a count.
    output     [15:0] rx_drop_cnt,
    output     [15:0] ram_wr_cnt,      // payload writes seen by udp_rx
    output     [10:0] ram_wr_addr,     // last address written
    output     [7:0]  ram_wr_data,     // last byte written

    // (ld_cap_pay declared above)

    input      [10:0] snf_raddr,
    output     [15:0] snf_rdata,
    output     [10:0] snf_wr_ptr,
    output     [15:0] snf_count,       // PHY identifier register 2

    // ---- diagnostics ----
    output reg        dbg_arp_found,   // sticky: an ARP reply was generated
    output reg [15:0] dbg_rx_frames,  // carrier arrivals seen by the PHY
    output reg [15:0] dbg_udp_rx,     // datagrams that survived IP/UDP checks
    // dbg_tx_frames counts mac_data_valid rising edges, i.e. frames the vendor
    // MAC actually put on the wire.  Together with dbg_rx_frames it splits the
    // receive chain from the transmit chain: frames arriving but nothing
    // transmitted means the received bytes never passed the MAC checks.
    output reg [15:0] dbg_tx_frames,
    // dbg_rec_error counts frames the vendor MAC rejected.  It is the vendor's
    // own aggregate - mac_rec_error | ip_checksum_error | ip_addr_check_error -
    // where mac_rec_error covers the preamble match, the ethertype filter and the
    // FCS comparison.  This is the signal that separates "frames arrive" from
    // "frames arrive and are accepted", which no counter derived from rx_dv can do.
    output reg [15:0] dbg_rec_error,
    output reg [15:0] dbg_tx_done      // mac_send_end rising edges
);

    // ==================================================================
    // PHY management, fabric domain
    // ==================================================================
    // PHY management.
    //
    // The previous block drove MDIO through an explicit IOBUF and was write
    // only.  It is replaced by the vendor's proven read/write master plus a sweep
    // sequencer, because the board now reports "no link" from the FPGA while the
    // PHY link LEDs are lit - which can only mean the MDIO path does not work,
    // and that had never been tested.
    wire        phy_done;

    eth_phy_probe #(
        .CLK_HZ    (200_000_000),
        .RST_CLKS  (2_000_000),        // 10 ms
        .WAIT_CLKS (20_000_000)        // 100 ms
    ) u_probe (
        .clk         (clk),
        .rst_n       (rst_n),
        .mdc         (phy_mdc),
        .mdio        (phy_mdio),       // tristate handled inside mdio_rw
        .phy_rst_n   (phy_rst_n),
        .found_valid (probe_valid),
        .found_addr  (probe_addr),
        .phy_id      (probe_id),
        .probe_done  (phy_done)
    );

    assign phy_cfg_done = phy_done;
    assign mdio_step    = phy_done ? 3'd5 : 3'd0;

    // ==================================================================
    // RGMII <-> GMII
    // ==================================================================
    wire        gmii_rx_clk, gmii_tx_clk;
    wire [7:0]  gmii_rxd;
    wire        gmii_rx_dv, gmii_rx_er;
    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire        gmii_crs, gmii_col;

    util_gmii_to_rgmii u_conv (
        .rst_n          (rst_n),
        .sys_clk        (clk),
        .rgmii_rxc      (rgmii_rxc),
        .reset          (1'b0),
        .rgmii_td       (rgmii_txd),
        .rgmii_tx_ctl   (rgmii_txctl),
        .rgmii_txc      (rgmii_txc),
        .rgmii_rd       (rgmii_rxd),
        .rgmii_rx_ctl   (rgmii_rxctl),
        .gmii_rx_clk    (gmii_rx_clk),
        .gmii_tx_clk    (gmii_tx_clk),
        .gmii_rxd       (gmii_rxd),
        .gmii_rx_dv     (gmii_rx_dv),
        .gmii_rx_er     (gmii_rx_er),
        .gmii_txd       (gmii_txd),
        .gmii_tx_en     (gmii_tx_en),
        .gmii_tx_er     (1'b0),
        .gmii_crs       (gmii_crs),
        .gmii_col       (gmii_col),
        .idly_tap       (idly_tap),
        .idly_ld        (idly_ld),
        .idly_tap_out   (idly_tap_out),
        .speed_selection(2'b10),       // gigabit
        .duplex_mode    (1'b1)
    );

    // ---- register the GMII inputs and outputs, as mac_test.v does ----
    // The demo inserts one register on each side (gmii_rxd_d0 / gmii_txd_tmp);
    // keeping that structure means the vendor RTL sees the timing it was written
    // and tested against.
    reg [7:0] gmii_rxd_d0;
    reg       gmii_rx_dv_d0;

    always @(posedge gmii_rx_clk or negedge rst_n) begin
        if (!rst_n) begin
            gmii_rxd_d0   <= 8'd0;
            gmii_rx_dv_d0 <= 1'b0;
        end else begin
            gmii_rxd_d0   <= gmii_rxd;
            gmii_rx_dv_d0 <= gmii_rx_dv;
        end
    end

    // Declared here because the output register below drives them.
    wire        mac_data_valid;
    wire [7:0]  mac_tx_data;
    wire        mac_send_end;

    reg [7:0] gmii_txd_tmp;
    reg       gmii_tx_en_tmp;

    always @(posedge gmii_tx_clk or negedge rst_n) begin
        if (!rst_n) begin
            gmii_txd_tmp   <= 8'd0;
            gmii_tx_en_tmp <= 1'b0;
        end else begin
            gmii_txd_tmp   <= mac_tx_data;
            gmii_tx_en_tmp <= mac_data_valid;
        end
    end

    assign gmii_txd   = gmii_txd_tmp;
    assign gmii_tx_en = gmii_tx_en_tmp;

    // ==================================================================
    // Vendor MAC
    // ==================================================================
    wire        arp_found;
    wire        mac_not_exist;
    assign arp_resolved = ~mac_not_exist;

    // ------------------------------------------------------------------
    // ARP request generator
    // ------------------------------------------------------------------
    // mac_not_exist is asserted while arp_cache holds no entry for PEER_IP, and
    // the cache only learns from a received ARP reply - which only happens if we
    // ask.  So a request is emitted every ~120 ms for as long as the cache is
    // empty, and stops by itself once the peer answers.
    //
    // The request is broadcast at the Ethernet level because arp_cache returns
    // ff:ff:ff:ff:ff:ff whenever the lookup misses, which is exactly what an ARP
    // request needs.
    //
    // A pulse rather than a level, because arp_tx retriggers from IDLE: holding
    // the request high would emit back-to-back requests at line rate.
    reg [26:0] arp_tmr;
    reg [4:0]  arp_hold;

    always @(posedge gmii_tx_clk or negedge rst_n) begin
        if (!rst_n) begin
            arp_tmr  <= 27'd0;
            arp_hold <= 5'd0;
        end else begin
            if (arp_tmr == 27'd0) begin
                arp_hold <= 5'd16;                 // 128 ns, plenty for arp_tx
                arp_tmr  <= 27'd15_000_000;        // ~120 ms at 125 MHz
            end else begin
                arp_tmr <= arp_tmr - 27'd1;
            end
            if (arp_hold != 5'd0) arp_hold <= arp_hold - 5'd1;
        end
    end

    wire arp_request_req = (arp_hold != 5'd0) && mac_not_exist;
    wire        mac_rec_error;
    wire        mac_mac_err;
    wire        mac_ip_csum_err;
    wire        mac_ip_addr_err;

    wire [7:0]  udp_rec_ram_rdata;
    wire [10:0] udp_rec_ram_read_addr;
    wire [15:0] udp_rec_data_length;
    wire        udp_rec_data_valid;
    wire        dbg_ram_wr_en;
    wire [10:0] dbg_ram_wr_addr;
    wire [7:0]  dbg_ram_wr_data;

    // Count payload writes and remember the last one, so "was the RAM written at
    // all" becomes a measurement instead of an inference.
    reg [15:0] ram_wr_cnt_r;
    reg [10:0] ram_wr_addr_r;
    reg [7:0]  ram_wr_data_r;

    always @(posedge gmii_rx_clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_wr_cnt_r  <= 16'd0;
            ram_wr_addr_r <= 11'd0;
            ram_wr_data_r <= 8'd0;
        end else if (dbg_ram_wr_en) begin
            if (ram_wr_cnt_r != 16'hFFFF) ram_wr_cnt_r <= ram_wr_cnt_r + 16'd1;
            ram_wr_addr_r <= dbg_ram_wr_addr;
            ram_wr_data_r <= dbg_ram_wr_data;
        end
    end

    assign ram_wr_cnt  = ram_wr_cnt_r;
    assign ram_wr_addr = ram_wr_addr_r;
    assign ram_wr_data = ram_wr_data_r;

    reg  [7:0]  tx_ram_wr_data;
    reg         tx_ram_wr_en;
    wire        udp_ram_data_req;
    reg  [15:0] udp_send_data_length;
    wire        udp_tx_end;
    wire        almost_full;
    reg         udp_tx_req;

    mac_top u_mac (
        .gmii_tx_clk                 (gmii_tx_clk),
        .gmii_rx_clk                 (gmii_rx_clk),
        .rst_n                       (rst_n),

        .source_mac_addr             (LOCAL_MAC),
        .TTL                         (LOCAL_TTL),
        .source_ip_addr              (LOCAL_IP),
        .destination_ip_addr         (PEER_IP),

        .udp_send_source_port        (LOCAL_PORT),
        .udp_send_destination_port   (LOCAL_PORT),

        .ram_wr_data                 (tx_ram_wr_data),
        .ram_wr_en                   (tx_ram_wr_en),
        .udp_ram_data_req            (udp_ram_data_req),
        .udp_send_data_length        (udp_send_data_length),
        .udp_tx_end                  (udp_tx_end),
        .almost_full                 (almost_full),
        .udp_tx_req                  (udp_tx_req),
        .arp_request_req             (arp_request_req),

        .mac_send_end                (mac_send_end),
        .mac_data_valid              (mac_data_valid),
        .mac_tx_data                 (mac_tx_data),

        .rx_dv                       (gmii_rx_dv_d0),
        .mac_rx_datain               (gmii_rxd_d0),

        .udp_rec_ram_rdata           (udp_rec_ram_rdata),
        .udp_rec_ram_read_addr       (udp_rec_ram_read_addr),
        .udp_rec_data_length         (udp_rec_data_length),
        .udp_rec_data_valid          (udp_rec_data_valid),
        .dbg_ram_wr_en               (dbg_ram_wr_en),
        .dbg_ram_wr_addr             (dbg_ram_wr_addr),
        .dbg_ram_wr_data             (dbg_ram_wr_data),

        .arp_found                   (arp_found),
        .mac_not_exist               (mac_not_exist),
        .dbg_rec_error               (mac_rec_error),
        .dbg_mac_err                 (mac_mac_err),
        .dbg_ip_csum_err             (mac_ip_csum_err),
        .dbg_ip_addr_err             (mac_ip_addr_err)
    );

    // ==================================================================
    // Diagnostics
    // ==================================================================
    // dbg_rx_frames counts carrier arrivals, which happens before any parsing, so
    // a zero means nothing at all reaches the MAC.  dbg_udp_rx counts datagrams
    // that passed the preamble check, the ethertype filter and the FCS.
    // Comparing the two is the point: frames seen but none accepted means the wire
    // is alive and the frames are being rejected.
    reg        rx_dv_q;
    reg        udp_dv_q;

    always @(posedge gmii_rx_clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_dv_q       <= 1'b0;
            udp_dv_q      <= 1'b0;
            dbg_rx_frames <= 16'd0;
            dbg_udp_rx    <= 16'd0;
        end else begin
            rx_dv_q <= gmii_rx_dv_d0;
            // udp_rec_data_valid holds high between datagrams, so count its rising
            // edge; counting the level inflates this by every idle cycle.
            udp_dv_q <= udp_rec_data_valid;
            if (gmii_rx_dv_d0 && !rx_dv_q)
                dbg_rx_frames <= dbg_rx_frames + 16'd1;
            if (udp_rec_data_valid && !udp_dv_q)
                dbg_udp_rx <= dbg_udp_rx + 16'd1;
        end
    end

    always @(posedge gmii_rx_clk or negedge rst_n) begin
        if (!rst_n) dbg_arp_found <= 1'b0;
        else if (arp_found) dbg_arp_found <= 1'b1;
    end

    // Transmit-side evidence.  mac_data_valid is the vendor MAC telling the GMII
    // interface "here is a byte", so a rising edge means a frame has started.

    reg mac_dv_q, mac_end_q;

    always @(posedge gmii_tx_clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_dv_q      <= 1'b0;
            mac_end_q     <= 1'b0;
            dbg_tx_frames <= 16'd0;
            dbg_tx_done   <= 16'd0;
        end else begin
            mac_dv_q  <= mac_data_valid;
            mac_end_q <= mac_send_end;
            if (mac_data_valid && !mac_dv_q)
                dbg_tx_frames <= dbg_tx_frames + 16'd1;
            if (mac_send_end && !mac_end_q)
                dbg_tx_done <= dbg_tx_done + 16'd1;
        end
    end

    reg rec_err_q, mac_err_q, csum_err_q, addr_err_q;

    always @(posedge gmii_rx_clk or negedge rst_n) begin
        if (!rst_n) begin
            rec_err_q       <= 1'b0;
            mac_err_q       <= 1'b0;
            csum_err_q      <= 1'b0;
            addr_err_q      <= 1'b0;
            dbg_rec_error   <= 16'd0;
            dbg_mac_err     <= 16'd0;
            dbg_ip_csum_err <= 16'd0;
            dbg_ip_addr_err <= 16'd0;
        end else begin
            rec_err_q  <= mac_rec_error;
            mac_err_q  <= mac_mac_err;
            csum_err_q <= mac_ip_csum_err;
            addr_err_q <= mac_ip_addr_err;
            if (mac_rec_error    && !rec_err_q)  dbg_rec_error   <= dbg_rec_error   + 16'd1;
            if (mac_mac_err      && !mac_err_q)  dbg_mac_err     <= dbg_mac_err     + 16'd1;
            if (mac_ip_csum_err  && !csum_err_q) dbg_ip_csum_err <= dbg_ip_csum_err + 16'd1;
            if (mac_ip_addr_err  && !addr_err_q) dbg_ip_addr_err <= dbg_ip_addr_err + 16'd1;
        end
    end

    // Raw capture, on the same byte stream the MAC consumes.
    eth_sniffer u_snf (
        .clk        (gmii_rx_clk),
        .rst_n      (rst_n),
        .rx_data    (gmii_rxd),
        .rx_dv      (gmii_rx_dv),
        .raddr      (snf_raddr),
        .rdata      (snf_rdata),
        .wr_ptr     (snf_wr_ptr),
        .byte_count (snf_count)
    );

    // ==================================================================
    // Receive: vendor RAM -> loader
    // ==================================================================
    // udp_rec_data_length includes the eight byte UDP header, so the payload is
    // length-8 bytes starting at RAM address 0.  The RAM read is registered, so a
    // byte arrives one cycle after its address was presented.
    // ------------------------------------------------------------------
    // The burst is driven by an address that only ever counts up, and ends
    // when it reaches the payload length.  An earlier version used a down
    // counter testing "<= 1"; if that counter ever reached zero while the
    // burst was still marked active it wrapped to 0xFFFF, the test never
    // fired again, and the address ran off the end of the RAM reading
    // unwritten zeroes.  An increasing address cannot get stuck that way.
    // ------------------------------------------------------------------
    reg [10:0] rx_addr;      // address currently presented to the RAM
    reg        rx_busy;      // address phase in progress
    reg        rx_push;      // push valid data, one cycle behind rx_busy

    wire [15:0] rx_pay_len = (udp_rec_data_length >= 16'd8)
                             ? (udp_rec_data_length - 16'd8) : 16'd0;

    assign udp_rec_ram_read_addr = rx_addr;

    wire       ld_tvalid_w;

    wire [7:0] ld_tdata_w = udp_rec_ram_rdata;
    wire       ld_tlast_w;
    wire       ld_ready_w;
    wire [7:0] ld_rdata_w;
    wire       ld_rvalid_w;
    wire       ld_rready_w;

    // ------------------------------------------------------------------
    // udp_rec_data_valid is NOT a pulse.
    //
    // udp_rx.v only assigns it in REC_END (set) and REC_END_WAIT (clear),
    // and has no else branch, so it holds its value in every other state:
    // it goes high when a datagram completes and STAYS high through IDLE and
    // the whole reception of the NEXT packet.  Treating it as a pulse let the
    // burst restart immediately every time it finished, which is why the
    // forwarded-byte count saturated and the reads ran off the end of the
    // written payload into untouched zeroes.
    //
    // So: start a burst on its rising edge only.  The length is latched at
    // that moment, and a hard cycle limit guarantees the burst ends even if
    // some future condition keeps addr_last from matching.
    // ------------------------------------------------------------------
    reg        dv_q;          // udp_rec_data_valid, delayed one cycle
    reg [10:0] rx_len_q;      // payload length latched at burst start
    reg [11:0] rx_guard;      // hard limit on burst length
    reg [15:0] rx_drop_cnt_r; // rising edges ignored because a burst was running

    wire dv_rise  = udp_rec_data_valid && !dv_q;
    wire [10:0] pay_lim = (rx_pay_len > 16'd2047) ? 11'd2047 : rx_pay_len[10:0];
    wire        addr_last = (rx_addr + 11'd1 == rx_len_q);

    always @(posedge gmii_rx_clk or negedge rst_n) begin
        if (!rst_n) begin
            dv_q     <= 1'b0;
            rx_addr  <= 11'd0;
            rx_len_q <= 11'd0;
            rx_busy  <= 1'b0;
            rx_push  <= 1'b0;
            rx_guard      <= 12'd0;
            rx_drop_cnt_r <= 16'd0;
            end else begin
            dv_q <= udp_rec_data_valid;

            // Registered, so the push phase lands exactly one cycle behind
            // the address phase - which is what the RAM's one cycle read
            // latency needs, and it also covers the final byte.
            rx_push <= rx_busy;
            // A datagram completing while the previous one is still in flight is
            // lost for good, so at least record it.
            if (dv_rise && rx_busy)
                rx_drop_cnt_r <= rx_drop_cnt_r + 16'd1;

            if (dv_rise && !rx_busy && (pay_lim != 11'd0)) begin
                rx_len_q <= pay_lim;      // latch: immune to later changes
                rx_addr  <= 11'd0;
                rx_busy  <= 1'b1;
                rx_guard <= 12'd0;
            end else if (rx_busy) begin
                rx_guard <= rx_guard + 12'd1;
                if (addr_last || (rx_guard == 12'd2047))
                    rx_busy <= 1'b0;     // done, or forced to stop
                else
                    rx_addr <= rx_addr + 11'd1;
            end else begin
                rx_guard <= 12'd0;
            end
        end
    end
    // ------------------------------------------------------------------
    // Diagnostic capture of the loader feed
    // ------------------------------------------------------------------
    reg [7:0]  ld_cap [0:63];
    reg [5:0]  ld_cap_wp;
    reg [15:0] ld_cap_n;
    reg [15:0] ld_cap_l;
    reg [15:0] ld_cap_p;
    reg        rx_active_q;
    reg [7:0]  ld_cap_q;

    always @(posedge gmii_rx_clk or negedge rst_n) begin
        if (!rst_n) begin
            ld_cap_wp   <= 6'd0;
            ld_cap_n    <= 16'd0;
            ld_cap_l    <= 16'd0;
            ld_cap_p    <= 16'd0;
            rx_active_q <= 1'b0;
        end else begin
            rx_active_q <= rx_busy;
            if (rx_busy && !rx_active_q) begin
                ld_cap_l <= udp_rec_data_length;
                ld_cap_p <= rx_pay_len;
            end
            if (rx_push) begin
                ld_cap[ld_cap_wp] <= udp_rec_ram_rdata;
                ld_cap_wp <= ld_cap_wp + 6'd1;
                if (ld_cap_n != 16'hFFFF) ld_cap_n <= ld_cap_n + 16'd1;
            end
        end
    end

    always @(posedge gmii_rx_clk) ld_cap_q <= ld_cap[ld_cap_raddr];

    assign ld_cap_rdata = ld_cap_q;
    assign ld_cap_count = ld_cap_n;
    assign ld_cap_len   = ld_cap_l;
    assign ld_cap_pay   = ld_cap_p;


    assign ld_tvalid_w = rx_push;
    assign ld_tlast_w  = rx_push && addr_last;

    // ==================================================================
    // Transmit: loader -> udp_tx
    // ==================================================================
    // udp_tx does not take a pre-loaded payload.  Its checksum state machine
    // computes the UDP checksum from the byte stream as it arrives on
    // ram_wr_data, so the bytes must be presented in step with that machine:
    //
    //   1. raise udp_tx_req and hold it
    //   2. udp_tx answers with a single cycle udp_ram_data_req pulse
    //      (HEADER_CHECKSUM, checksum_cnt == 5)
    //   3. from that cycle on, stream one byte per cycle on ram_wr_data
    //      with ram_wr_en high, for udp_send_data_length bytes
    //
    // The earlier version filled the vendor RAM first and only then asserted
    // udp_tx_req.  The frame still went out (the payload was in the FIFO and the
    // headers were right) but the checksum was computed over a stream that had
    // already stopped, so the host silently dropped every reply.
    //
    // The loader does not drive m_axis_tlast (it is tied low), so the end of a
    // reply is still detected by an idle gap on its stream.
    localparam [2:0] TX_COLLECT = 3'd0,   // buffering the loader reply
                     TX_REQUEST = 3'd1,   // udp_tx_req held, waiting for the ack
                     TX_STREAM  = 3'd2,   // pushing bytes at udp_tx
                     TX_SENDING = 3'd3;   // waiting for udp_tx_end

    // A READOUT reply is 256 lanes x 4 bytes = 1024 bytes, so an 8 bit
    // pointer and a 256 entry buffer both wrapped on it: the write pointer
    // silently overwrote earlier bytes, and the "last byte" test below
    // compared against tx_len[7:0], which is zero for any multiple of 256,
    // so the stream never terminated.  Wide enough for the largest reply
    // the loader can produce.
    wire [8:0]  tx_q;        // {tlast, data} from the loader; declared here
                             // because the collect state reads its tlast bit
    reg [7:0]  tx_buf [0:1023];
    reg [9:0]  tx_wr_ptr;
    reg [9:0]  tx_rd_ptr;
    reg [15:0] tx_len;
    reg [2:0]  tx_st;
    reg [15:0] tx_gap;

    // Ready for the loader only while collecting; one cycle per accepted byte.
    assign ld_rready_w = (tx_st == TX_COLLECT);

    always @(posedge gmii_rx_clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_wr_ptr            <= 10'd0;
            tx_rd_ptr            <= 10'd0;
            tx_len               <= 16'd0;
            tx_st                <= TX_COLLECT;
            tx_gap               <= 16'd0;
            tx_ram_wr_en         <= 1'b0;
            tx_ram_wr_data       <= 8'd0;
            udp_send_data_length <= 16'd0;
            udp_tx_req           <= 1'b0;
        end else begin
            tx_ram_wr_en <= 1'b0;

            case (tx_st)
            TX_COLLECT: begin
                if (ld_rvalid_w && ld_rready_w) begin
                    tx_buf[tx_wr_ptr] <= ld_rdata_w;
                    tx_wr_ptr         <= tx_wr_ptr + 10'd1;
                    // The loader marks the final byte of every reply with tlast,
                    // carried through the FIFO beside the byte, so the end is known
                    // instead of guessed.  The idle-gap timer truncated a reply
                    // that paused mid-stream.  1023 is a backstop: the buffer
                    // cannot hold more.
                    if (tx_q[8] || (tx_wr_ptr == 10'd1023)) begin
                        tx_len               <= {6'd0, tx_wr_ptr + 10'd1};
                        udp_send_data_length <= {6'd0, tx_wr_ptr + 10'd1};
                        tx_rd_ptr            <= 10'd0;
                        tx_st                <= TX_REQUEST;
                    end
                end
            end

            TX_REQUEST: begin
                udp_tx_req <= 1'b1;          // held until udp_tx acknowledges
                if (udp_ram_data_req) begin
                    tx_rd_ptr <= 10'd0;
                    tx_st     <= TX_STREAM;
                end
            end

            TX_STREAM: begin
                udp_tx_req   <= 1'b0;
                tx_ram_wr_en <= 1'b1;
                tx_ram_wr_data <= tx_buf[tx_rd_ptr];
                if (tx_rd_ptr + 10'd1 == tx_len[9:0]) begin
                    tx_st <= TX_SENDING;
                end else begin
                    tx_rd_ptr <= tx_rd_ptr + 10'd1;
                end
            end

            TX_SENDING: begin
                udp_tx_req <= 1'b0;
                if (udp_tx_end) begin
                    tx_wr_ptr <= 10'd0;
                    tx_rd_ptr <= 10'd0;
                    tx_st     <= TX_COLLECT;
                end
            end
            default: tx_st <= TX_COLLECT;
            endcase
        end
    end

    // ==================================================================
    // Clock boundary to the 200 MHz loader
    // ==================================================================
    wire [8:0] rx_q;
    wire       tx_fifo_full;
    wire       rx_empty, tx_empty;

    eth_async_fifo #(.DATA_W(9), .AW(6)) u_fifo_rx (
        .wclk   (gmii_rx_clk),
        .wrst_n (rst_n),
        .wen    (ld_tvalid_w && !ld_ready_w),
        .wdata  ({ld_tlast_w, ld_tdata_w}),
        .wfull  (ld_ready_w),
        .rclk   (clk),
        .rrst_n (rst_n),
        .ren    (ld_tready && !rx_empty),
        .rdata  (rx_q),
        .rempty (rx_empty)
    );

    assign ld_tdata  = rx_q[7:0];
    assign rx_drop_cnt = rx_drop_cnt_r;
    assign ld_tvalid = !rx_empty;
    assign ld_tlast  = rx_q[8];

    eth_async_fifo #(.DATA_W(9), .AW(6)) u_fifo_tx (
        .wclk   (clk),
        .wrst_n (rst_n),
        .wen    (ld_rvalid && ld_rready),
        .wdata  ({ld_rlast, ld_rdata}),
        .wfull  (tx_fifo_full),
        .rclk   (gmii_rx_clk),
        .rrst_n (rst_n),
        .ren    (ld_rready_w && !tx_empty),
        .rdata  (tx_q),
        .rempty (tx_empty)
    );
    // The FIFO full flag used to be wired straight into ld_rready, so the loader
    // was told "cannot accept" whenever the FIFO was EMPTY - which is the power-up
    // state - and never handed over a single byte.  Ready is the inverse of full.
    assign ld_rready = ~tx_fifo_full;


    assign ld_rdata_w  = tx_q[7:0];
    assign ld_rvalid_w = !tx_empty;

endmodule