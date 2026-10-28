`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// tb_eth_shim  -  the loader <-> MAC shim inside eth_top
// -----------------------------------------------------------------------------
// This exists because the shim was the one piece of the Ethernet datapath with
// no coverage at all, and four separate transmit faults lived in it:
//
//   1. udp_tx_req gated on udp_ram_data_req, which udp_tx only produces after a
//      transfer has started - a deadlock.
//   2. The transmit FIFO full flag wired into ld_rready, so at power-up (FIFO
//      empty) the loader was told it could not send.
//   3. The byte captured one cycle before the FIFO was popped, duplicating the
//      first byte.
//   4. The payload pre-loaded into the vendor RAM and only then transmitted,
//      which meant udp_tx's checksum state machine saw a stream that had already
//      stopped and computed the checksum over idle bytes.  The frame went out
//      with correct headers and a wrong checksum and the host dropped it.
//
// Every one of them is visible here in a few microseconds.
//
// The vendor MAC and the RGMII converter are not simulated: the converter's
// clock is forced, and the signals the shim exchanges with the MAC are driven
// directly.  That keeps the test focused on the code under test rather than on
// the PHY primitives.
// -----------------------------------------------------------------------------
module tb_eth_shim;

    // ------------------------------------------------------------------
    // Clocks and reset
    // ------------------------------------------------------------------
    reg clk200 = 1'b0;      // fabric / loader side
    reg clk125 = 1'b0;      // wire side, the shim's clock
    reg rst_n  = 1'b0;

    always #2.5 clk200 = ~clk200;   // 200 MHz
    always #4.0 clk125 = ~clk125;   // 125 MHz

    integer errors = 0;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    wire [7:0] ld_tdata;
    wire       ld_tvalid;
    wire       ld_tlast;
    reg        ld_tready = 1'b0;

    reg  [7:0] ld_rdata  = 8'd0;
    reg        ld_rvalid = 1'b0;
    reg        ld_rlast  = 1'b0;
    wire       ld_rready;

    reg  [5:0]  ld_cap_raddr = 6'd0;

    eth_top u_dut (
        .clk            (clk200),
        .rst_n          (rst_n),

        .rgmii_rxd      (4'd0),
        .rgmii_rxctl    (1'b0),
        .rgmii_rxc      (clk125),
        .rgmii_txd      (),
        .rgmii_txctl    (),
        .rgmii_txc      (),

        .phy_mdc        (),
        .phy_mdio       (),
        .phy_rst_n      (),

        .ld_tdata       (ld_tdata),
        .ld_tvalid      (ld_tvalid),
        .ld_tready      (ld_tready),
        .ld_tlast       (ld_tlast),

        .ld_rdata       (ld_rdata),
        .ld_rvalid      (ld_rvalid),
        .ld_rready      (ld_rready),
        .ld_rlast       (ld_rlast),

        .phy_cfg_done   (),
        .mdio_step      (),
        .probe_valid    (),
        .probe_addr     (),
        .probe_id       (),
        .arp_resolved   (),

        .idly_tap       (5'd31),
        .idly_ld        (1'b0),
        .idly_tap_out   (),

        .dbg_mac_err    (),
        .dbg_ip_csum_err(),
        .dbg_ip_addr_err(),

        .ld_cap_raddr   (ld_cap_raddr),
        .ld_cap_rdata   (),
        .ld_cap_count   (),
        .ld_cap_len     (),
        .ld_cap_pay     (),

        .ram_wr_cnt     (),
        .ram_wr_addr    (),
        .ram_wr_data    (),

        .snf_raddr      (11'd0),
        .snf_rdata      (),
        .snf_wr_ptr     (),
        .snf_count      (),

        .dbg_arp_found  (),
        .dbg_rx_frames  (),
        .dbg_udp_rx     (),
        .dbg_tx_frames  (),
        .dbg_rec_error  (),
        .dbg_tx_done    ()
    );

    // The RGMII converter is not part of this test: its clock is forced so the
    // shim runs on the real 125 MHz wire clock without needing the PHY
    // primitives to model a delay line.
    reg clk125_force = 1'b0;
    always #4.0 clk125_force = ~clk125_force;
    initial force u_dut.gmii_rx_clk = clk125_force;

    // ------------------------------------------------------------------
    // Vendor-side signals the shim talks to, driven by the test
    // ------------------------------------------------------------------
    reg        f_udp_valid;         // udp_rec_data_valid
    reg [15:0] f_udp_len;           // udp_rec_data_length
    reg [7:0]  f_udp_rdata;         // udp_rec_ram_rdata
    reg        f_ram_req;           // udp_ram_data_req  (one cycle ack)
    reg        f_tx_end;            // udp_tx_end

    initial begin
        f_udp_valid = 1'b0;
        f_udp_len   = 16'd13;   // 8 header + 5 payload, fixed from t=0
        f_udp_rdata = 8'd0;
        f_ram_req   = 1'b0;
        f_tx_end    = 1'b0;
        force u_dut.udp_rec_data_valid = f_udp_valid;
        force u_dut.udp_rec_data_length = f_udp_len;
        force u_dut.udp_rec_ram_rdata = f_udp_rdata;
        force u_dut.udp_ram_data_req = f_ram_req;
        force u_dut.udp_tx_end = f_tx_end;
    end

    // Shadow of the receive RAM: answers one cycle after the address, which is
    // what the real block memory does.
    reg [7:0] ram_model [0:2047];
    always @(posedge clk125_force)
        f_udp_rdata <= ram_model[u_dut.udp_rec_ram_read_addr];

    // ------------------------------------------------------------------
    // Observations
    // ------------------------------------------------------------------
    integer rx_bytes = 0;
    reg [7:0] rx_seen [0:63];

    always @(posedge clk200) begin
        if (ld_tvalid && ld_tready && rx_bytes < 64) begin
            rx_seen[rx_bytes] = ld_tdata;
            rx_bytes = rx_bytes + 1;
        end
    end

    integer tx_bytes = 0;
    reg [7:0] tx_seen [0:63];

    always @(posedge clk125_force) begin
        if (u_dut.tx_ram_wr_en && tx_bytes < 64) begin
            tx_seen[tx_bytes] = u_dut.tx_ram_wr_data;
            tx_bytes = tx_bytes + 1;
        end
    end

    // ------------------------------------------------------------------
    // Test 1: a datagram arrives and its payload must reach the loader
    // ------------------------------------------------------------------
    task test_rx;
        integer i;
        begin
            $display("");
            $display("  ---- test 1: receive path ----");

            // payload A5 04 00 00 AB at RAM addresses 0..4
            ram_model[0] = 8'hA5;
            ram_model[1] = 8'h04;
            ram_model[2] = 8'h00;
            ram_model[3] = 8'h00;
            ram_model[4] = 8'hAB;

            rx_bytes = 0;
            ld_tready = 1'b1;               // loader is always willing here

            // udp_rec_data_valid is a LEVEL in the real design: it rises when a
            // datagram completes and stays high until the next one finishes.
            // Holding it for 20 cycles is what exposed the burst restarting.
            f_udp_valid = 1'b1;
            repeat (20) @(posedge clk125_force);
            f_udp_valid = 1'b0;

            repeat (200) @(posedge clk200);

            if (rx_bytes != 5) begin
                $display("  FAIL: loader received %0d bytes, expected 5", rx_bytes);
                errors = errors + 1;
            end else if (rx_seen[0] !== 8'hA5 || rx_seen[1] !== 8'h04 ||
                         rx_seen[2] !== 8'h00 || rx_seen[3] !== 8'h00 ||
                         rx_seen[4] !== 8'hAB) begin
                $display("  FAIL: loader received %02X %02X %02X %02X %02X, expected A5 04 00 00 AB",
                         rx_seen[0], rx_seen[1], rx_seen[2], rx_seen[3], rx_seen[4]);
                errors = errors + 1;
            end else begin
                $display("  PASS: loader received A5 04 00 00 AB (5 bytes)");
            end

            // The level stays low now; the burst must not restart.
            repeat (500) @(posedge clk200);
            if (rx_bytes != 5) begin
                $display("  FAIL: loader received %0d bytes after the level dropped, expected 5", rx_bytes);
                errors = errors + 1;
            end else begin
                $display("  PASS: burst did not restart while the level was low");
            end

            for (i = 0; i < 5; i = i + 1) ram_model[i] = 8'd0;
        end
    endtask

    // ------------------------------------------------------------------
    // Test 2: the loader replies and the payload must be streamed at udp_tx
    // ------------------------------------------------------------------
    task test_tx;
        integer i;
        begin
            $display("");
            $display("  ---- test 2: transmit path ----");

            tx_bytes = 0;

            // A) ready must be usable straight after reset (the FIFO is empty)
            repeat (5) @(posedge clk125_force);
            if (ld_rready !== 1'b1) begin
                $display("  FAIL: ld_rready is %b with an empty FIFO, expected 1", ld_rready);
                errors = errors + 1;
            end else begin
                $display("  PASS: ld_rready is high with an empty FIFO");
            end

            // B) push an 8 byte reply
            for (i = 0; i < 8; i = i + 1) begin
                @(posedge clk200);
                ld_rdata  <= i[7:0] + 8'h10;
                ld_rvalid <= 1'b1;
                // hold until accepted
                while (!ld_rready) @(posedge clk200);
            end
            @(posedge clk200);
            ld_rvalid <= 1'b0;
            ld_rdata  <= 8'd0;

            // C) the shim must raise udp_tx_req and hold it
            repeat (600) @(posedge clk125_force);
            if (u_dut.udp_tx_req !== 1'b1) begin
                $display("  FAIL: udp_tx_req never asserted");
                errors = errors + 1;
            end else begin
                $display("  PASS: udp_tx_req asserted");
            end

            // D) udp_tx answers with a single cycle udp_ram_data_req
            @(posedge clk125_force);
            f_ram_req = 1'b1;
            @(posedge clk125_force);
            f_ram_req = 1'b0;

            // E) the payload must stream out, exactly once each
            repeat (300) @(posedge clk125_force);

            if (tx_bytes != 8) begin
                $display("  FAIL: streamed %0d bytes, expected 8", tx_bytes);
                errors = errors + 1;
            end else if (tx_seen[0] !== 8'h10 || tx_seen[7] !== 8'h17) begin
                $display("  FAIL: streamed %02X..%02X, expected 10..17",
                         tx_seen[0], tx_seen[7]);
                errors = errors + 1;
            end else begin
                $display("  PASS: streamed 8 bytes 10..17 at udp_tx, no duplicates");
            end

            // F) finish the transfer so the shim returns to collecting
            @(posedge clk125_force);
            f_tx_end = 1'b1;
            @(posedge clk125_force);
            f_tx_end = 1'b0;
            repeat (50) @(posedge clk125_force);
        end
    endtask

    // ------------------------------------------------------------------
    initial begin
        $display("");
        $display("========== tb_eth_shim ==========");

        repeat (10) @(posedge clk200);
        rst_n = 1'b1;
        repeat (50) @(posedge clk200);

        test_rx;
        test_tx;

        $display("");
        if (errors == 0)
            $display("ETH SHIM TB: ALL TESTS PASSED");
        else
            $display("ETH SHIM TB: %0d FAILURE(S)", errors);
        $display("=================================");
        $display("");
        $finish;
    end

endmodule