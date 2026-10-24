`timescale 1ns/1ps
`include "moe_params.vh"

// -----------------------------------------------------------------------------
// tb_axil - verify the AXI4-Lite bridge, not the engine
// -----------------------------------------------------------------------------
// Division of labour, deliberate:
//
//   tb_loader  proves the loader + engine end to end: 128 KiB of weights, the
//              activation vector, RUN, and 256 lanes matching ref_out.hex.
//
//   tb_axil    proves only that the AXI4-Lite bridge transports bytes faithfully
//              in both directions.  It does NOT reload the model, because doing
//              so costs 33,000 AXI transactions - twenty minutes of simulation
//              to re-test something tb_loader already covers.
//
// What it does check:
//   1. STATUS reads back as zero before anything is loaded
//   2. a RUN frame pushed through TXDATA arrives byte-for-byte intact - the
//      loader answers ERR_NOT_LOADED, which can only happen if magic, command,
//      length and CRC all survived the bridge
//   3. STATUS then reports that error, proving the register read path
//   4. a STATUS command produces an 8-byte reply; RXCOUNT reports 8 and RXDATA
//      pops those bytes in the right order
//
// Byte order through TXDATA is the thing most likely to be wrong in a bridge, and
// step 2 catches it exactly: any reordering breaks the CRC.
// -----------------------------------------------------------------------------
module tb_axil;

    reg clk;
    reg rst_n;

    reg  [31:0] awaddr;  reg awvalid; wire awready;
    reg  [31:0] wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;   wire bvalid;  reg bready;
    reg  [31:0] araddr;  reg arvalid;  wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;

    wire [7:0] s_axis_tdata;  wire s_axis_tvalid; wire s_axis_tready;
    wire [7:0] m_axis_tdata;  wire m_axis_tvalid; wire m_axis_tready;

    wire                     w_wr_en;
    wire [1:0]               w_wr_region;
    wire [`H_ADDR_W-1:0]     w_wr_addr;
    wire [`REGION_WCODE_W-1:0] w_wr_data;
    wire                     a_wr_en;
    wire [`H_ADDR_W-1:0]     a_wr_addr;
    wire [`ACT_W-1:0]        a_wr_data;
    wire        gemv_start, gemv_busy, gemv_done;
    wire        rd_start;
    wire [`E_ADDR_W-1:0] rd_start_lane;
    wire        rd_pause, rd_valid, rd_busy;
    wire [`E_ADDR_W-1:0] rd_lane;
    wire [1:0]  rd_byte;
    wire [7:0]  rd_data;
    wire        weights_ready, act_valid, busy;
    wire [7:0]  err_code;

    moe_proto_top u_top (
        .clk(clk), .rst_n(rst_n), .start(gemv_start),
        .busy(gemv_busy), .done(gemv_done),
        .w_wr_en(w_wr_en), .w_wr_region(w_wr_region),
        .w_wr_addr(w_wr_addr), .w_wr_data(w_wr_data),
        .act_wr_en(a_wr_en), .act_wr_addr(a_wr_addr), .act_wr_data(a_wr_data),
        .rd_start(rd_start), .rd_start_lane(rd_start_lane), .rd_pause(rd_pause),
        .rd_valid(rd_valid), .rd_lane(rd_lane), .rd_byte(rd_byte),
        .rd_data(rd_data), .rd_busy(rd_busy), .result_checksum()
    );

    moe_loader u_loader (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready), .s_axis_tlast(1'b0),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready), .m_axis_tlast(),
        .w_wr_en(w_wr_en), .w_wr_region(w_wr_region),
        .w_wr_addr(w_wr_addr), .w_wr_data(w_wr_data),
        .a_wr_en(a_wr_en), .a_wr_addr(a_wr_addr), .a_wr_data(a_wr_data),
        .gemv_start(gemv_start), .gemv_busy(gemv_busy), .gemv_done(gemv_done),
        .rd_start(rd_start), .rd_start_lane(rd_start_lane), .rd_pause(rd_pause),
        .rd_valid(rd_valid), .rd_lane(rd_lane), .rd_byte(rd_byte),
        .rd_data(rd_data), .rd_busy(rd_busy),
        .weights_ready(weights_ready), .act_valid(act_valid),
        .busy(busy), .err_code(err_code)
    );

    axil_loader_bridge u_bridge (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .weights_ready(weights_ready), .act_valid(act_valid),
        .busy(busy), .err_code(err_code)
    );

    initial begin clk = 1'b0; forever #2.5 clk = ~clk; end

    // Watchdog.  An earlier version of this testbench hung: the AXI handshake
    // loops wait forever if a ready never arrives, and a hung simulator produces
    // no log at all, which is indistinguishable from "still working".  A bounded
    // total run time turns that into a visible failure.
    initial begin
        #500000;                                    // 0.5 ms of simulated time
        $display("AXIL TB: TIMEOUT - simulation did not finish");
        $finish;
    end

    localparam [31:0] R_TXDATA  = 32'h00;
    localparam [31:0] R_STATUS  = 32'h04;
    localparam [31:0] R_RXDATA  = 32'h08;
    localparam [31:0] R_RXCOUNT = 32'h0C;

    // Blocking assignments: with non-blocking ones the handshake signals change
    // one cycle after the checks that follow them, so a word could be accepted
    // twice and the stream lost alignment.
    // Hold AW and W until each is actually accepted.  The previous version
    // asserted both for exactly one clock and then dropped them without looking
    // at awready; whenever the previous burst's response had not cleared yet,
    // awready was low, the write was silently lost, and the wait for bvalid hung
    // forever.  Checking ready immediately after @(posedge clk) samples the
    // pre-edge value, which is what the handshake is defined on; deasserting on
    // the following negedge keeps the driver out of the DUT's sampling window.
    task axi_write(input [31:0] a, input [31:0] d);
        reg aw_done, w_done;
        begin
            aw_done = 1'b0;
            w_done  = 1'b0;
            @(negedge clk);
            awaddr = a; awvalid = 1'b1;
            wdata  = d; wstrb = 4'hF; wvalid = 1'b1;
            bready = 1'b1;

            while (!aw_done || !w_done) begin
                @(posedge clk);
                if (!aw_done && awready) aw_done = 1'b1;
                if (!w_done  && wready)  w_done  = 1'b1;
            end

            @(negedge clk);
            awvalid = 1'b0;
            wvalid  = 1'b0;

            while (!bvalid) @(posedge clk);

            @(negedge clk);
            bready = 1'b0;
            @(negedge clk);
        end
    endtask

    task axi_read(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk);
            araddr  = a; arvalid = 1'b1; rready = 1'b1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            @(negedge clk);
            arvalid = 1'b0;
            while (!rvalid) @(posedge clk);
            d = rdata;
            @(negedge clk);
            rready = 1'b0;
        end
    endtask

    function [7:0] crc8;
        input [7:0] crc; input [7:0] din;
        integer i; reg [7:0] c;
        begin
            c = crc ^ din;
            for (i = 0; i < 8; i = i + 1) c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
            crc8 = c;
        end
    endfunction

    // Build a 5-byte command frame (magic, cmd, len=0, crc) and push it as two
    // AXI words, zero padded.  Padding is safe: the parser ignores every byte
    // that is not 0xA5 while waiting for a frame.
    task send_simple_cmd(input [7:0] c);
        reg [7:0] cr;
        begin
            cr = crc8(crc8(crc8(8'd0, c), 8'd0), 8'd0);
            // word 0 = A5, cmd, 00, 00
            axi_write(R_TXDATA, {8'h00, 8'h00, c, 8'hA5});
            // word 1 = crc, 00, 00, 00
            axi_write(R_TXDATA, {8'h00, 8'h00, 8'h00, cr});
        end
    endtask

    integer errors;
    reg [31:0] st, cnt, wd;
    reg [7:0]  cap [0:7];
    integer k;

    initial begin
        rst_n   = 1'b0;
        awaddr = 32'd0; awvalid = 1'b0;
        wdata  = 32'd0; wstrb = 4'hF; wvalid = 1'b0; bready = 1'b0;
        araddr = 32'd0; arvalid = 1'b0; rready = 1'b0;
        errors = 0;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---- 1. STATUS before anything ----
        axi_read(R_STATUS, st);
        $display("AXIL TB: status before load = %08x (expect 00000000)", st);
        if (st !== 32'h0) begin
            $display("AXIL TB: ERROR status should be zero before loading");
            errors = errors + 1;
        end

        $display("AXIL TB: step2 start t=%0t", $time);
        // ---- 2. RUN through AXI must arrive intact -> ERR_NOT_LOADED ----
        $display("AXIL TB: sending RUN through TXDATA...");
        send_simple_cmd(8'h03);
        repeat (30) @(posedge clk);

        axi_read(R_STATUS, st);
        $display("AXIL TB: status after RUN = %08x (expect err=02 in bits 15:8)", st);
        if (st[15:8] !== 8'h02) begin
            $display("AXIL TB: ERROR expected ERR_NOT_LOADED (02) - bytes did not survive the bridge");
            errors = errors + 1;
        end
        if (st[0] !== 1'b0) begin
            $display("AXIL TB: ERROR weights_ready should still be 0");
            errors = errors + 1;
        end

        $display("AXIL TB: step3 start t=%0t", $time);
        // ---- 3. STATUS command -> 8-byte reply, then RXCOUNT / RXDATA ----
        $display("AXIL TB: sending STATUS command...");
        send_simple_cmd(8'h04);
        repeat (40) @(posedge clk);

        axi_read(R_RXCOUNT, cnt);
        $display("AXIL TB: RXCOUNT = %0d (expect 8)", cnt);
        $display("AXIL TB:   dbg cnt=%0d rp=%0d wp=%0d fifo=%02x %02x %02x %02x %02x %02x %02x %02x",
                 u_bridge.rx_cnt, u_bridge.rx_rp, u_bridge.rx_wp,
                 u_bridge.rx_fifo[0], u_bridge.rx_fifo[1], u_bridge.rx_fifo[2], u_bridge.rx_fifo[3],
                 u_bridge.rx_fifo[4], u_bridge.rx_fifo[5], u_bridge.rx_fifo[6], u_bridge.rx_fifo[7]);
        if (cnt !== 32'd8) begin
            $display("AXIL TB: ERROR expected 8 reply bytes");
            errors = errors + 1;
        end

        $display("AXIL TB:   before read1: rp=%0d cnt=%0d", u_bridge.rx_rp, u_bridge.rx_cnt);
        axi_read(R_RXDATA, wd);
        cap[0] = wd[7:0];  cap[1] = wd[15:8]; cap[2] = wd[23:16]; cap[3] = wd[31:24];
        $display("AXIL TB:   after  read1: rp=%0d cnt=%0d data=%08x", u_bridge.rx_rp, u_bridge.rx_cnt, wd);
        axi_read(R_RXDATA, wd);
        cap[4] = wd[7:0];  cap[5] = wd[15:8]; cap[6] = wd[23:16]; cap[7] = wd[31:24];
        $display("AXIL TB:   after  read2: rp=%0d cnt=%0d data=%08x", u_bridge.rx_rp, u_bridge.rx_cnt, wd);

        $display("AXIL TB: reply = %02x %02x %02x %02x %02x %02x %02x %02x",
                 cap[0], cap[1], cap[2], cap[3], cap[4], cap[5], cap[6], cap[7]);
        // [0]=weights_ready [1]=act_valid [2]=busy [3]=any_err
        // [4]=act_valid ... per the status word layout: bytes are
        //   b0 = {5'b0, busy, act_valid, weights_ready}
        //   b2 = err_code
        if (cap[2] !== 8'h02) begin
            $display("AXIL TB: ERROR reply byte 2 should be err_code = 02, got %02x", cap[2]);
            errors = errors + 1;
        end
        if (cap[3] !== 8'h01) begin
            $display("AXIL TB: ERROR reply byte 3 should be any_error = 01, got %02x", cap[3]);
            errors = errors + 1;
        end

        axi_read(R_RXCOUNT, cnt);
        $display("AXIL TB: RXCOUNT after draining = %0d (expect 0)", cnt);
        if (cnt !== 32'd0) begin
            $display("AXIL TB: ERROR reply FIFO should be empty");
            errors = errors + 1;
        end

        if (errors == 0) $display("AXIL TB: ALL TESTS PASSED");
        else             $display("AXIL TB: %0d ERROR(S)", errors);
        $finish;
    end

endmodule
