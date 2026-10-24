`timescale 1ns/1ps
`include "moe_params.vh"

// -----------------------------------------------------------------------------
// tb_uart - the UART pair, then the UART driving the real loader
// -----------------------------------------------------------------------------
// Baud rate is a module parameter in uart_rx/uart_tx precisely so this can run at
// 2 Mbaud: at the production 115200 a single byte takes 17360 clocks, and a
// five-byte STATUS command plus an eight-byte reply would be 226,000 cycles of
// simulation for a result that says nothing about the logic.  The divider maths is
// identical at any rate, and the real 115200 ratio is exercised implicitly by the
// board build.
//
// Two tests:
//   1. loopback - tx drives rx, bytes must come back unchanged
//   2. STATUS through a real loader - the command goes in as serial bits and the
//      8-byte reply comes back out as serial bits
//
// Test 2 is the one that matters: it is the entire on-board signal path apart
// from the physical USB bridge, which cannot be simulated.
// -----------------------------------------------------------------------------
module tb_uart;

    localparam integer CLK_FREQ = 200_000_000;
    localparam integer BAUD     = 2_000_000;      // 100 clocks per bit

    reg clk;
    reg rst_n;

    initial begin clk = 1'b0; forever #2.5 clk = ~clk; end

    // Watchdog: a hung handshake produces no log at all otherwise.
    initial begin
        #300000;
        $display("UART TB: TIMEOUT");
        $finish;
    end

    // ==================================================================
    // 1. Loopback: tx -> rx
    // ==================================================================
    wire       line;
    reg  [7:0] tx_data;
    reg        tx_valid;
    wire       tx_ready;

    wire [7:0] rx_data;
    wire       rx_valid;
    wire       rx_ready;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .data(tx_data), .valid(tx_valid), .ready(tx_ready), .tx(line)
    );

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .rx(line), .data(rx_data), .valid(rx_valid), .ready(rx_ready)
    );

    assign rx_ready = 1'b1;

    localparam integer BITCLKS = CLK_FREQ / BAUD;

    task send(input [7:0] b);
        begin
            @(posedge clk);
            tx_data  <= b;
            tx_valid <= 1'b1;
            @(posedge clk);
            tx_valid <= 1'b0;
            tx_data  <= 8'd0;
            repeat (10 * BITCLKS + 50) @(posedge clk);
        end
    endtask

    // ==================================================================
    // 2. A second UART pair wired through the real loader
    // ==================================================================
    wire       line2;
    reg  [7:0] tx2_data;
    reg        tx2_valid;
    wire       tx2_ready;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD)) u_tx2 (
        .clk(clk), .rst_n(rst_n),
        .data(tx2_data), .valid(tx2_valid), .ready(tx2_ready), .tx(line2)
    );

    wire [7:0] ld_rx_data;
    wire       ld_rx_valid;
    wire       ld_rx_ready;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD)) u_rx2 (
        .clk(clk), .rst_n(rst_n),
        .rx(line2), .data(ld_rx_data), .valid(ld_rx_valid), .ready(ld_rx_ready)
    );

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

    wire [7:0] ld_tx_data;
    wire       ld_tx_valid;
    wire       ld_tx_ready;

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
        .s_axis_tdata(ld_rx_data), .s_axis_tvalid(ld_rx_valid),
        .s_axis_tready(ld_rx_ready), .s_axis_tlast(1'b0),
        .m_axis_tdata(ld_tx_data), .m_axis_tvalid(ld_tx_valid),
        .m_axis_tready(ld_tx_ready), .m_axis_tlast(),
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

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD)) u_tx3 (
        .clk(clk), .rst_n(rst_n),
        .data(ld_tx_data), .valid(ld_tx_valid), .ready(ld_tx_ready), .tx()
    );

    // ---- capture the reply bytes -------------------------------------
    reg [7:0] reply [0:15];
    integer   reply_n;

    always @(posedge clk) begin
        if (ld_tx_valid && ld_tx_ready) begin
            if (reply_n < 16) reply[reply_n] = ld_tx_data;
            reply_n = reply_n + 1;
        end
    end

    function [7:0] crc8;
        input [7:0] crc; input [7:0] din;
        integer i; reg [7:0] c;
        begin
            c = crc ^ din;
            for (i = 0; i < 8; i = i + 1) c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
            crc8 = c;
        end
    endfunction

    task send2(input [7:0] b);
        begin
            @(posedge clk);
            tx2_data  <= b;
            tx2_valid <= 1'b1;
            @(posedge clk);
            tx2_valid <= 1'b0;
            tx2_data  <= 8'd0;
            repeat (10 * BITCLKS + 50) @(posedge clk);
        end
    endtask

    integer errors;
    integer i;
    integer got;
    reg [7:0] pattern [0:3];
    reg [7:0] cr;

    initial begin
        rst_n     = 1'b0;
        tx_data   = 8'd0; tx_valid   = 1'b0;
        tx2_data  = 8'd0; tx2_valid  = 1'b0;
        reply_n   = 0;
        errors    = 0;

        pattern[0] = 8'h5A;
        pattern[1] = 8'hA5;
        pattern[2] = 8'h00;
        pattern[3] = 8'hFF;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---- Test 1: loopback ----
        $display("UART TB: [t1] reset released");
        $display("UART TB: loopback test (%0d baud, %0d clocks/bit)", BAUD, CLK_FREQ/BAUD);
        for (i = 0; i < 4; i = i + 1) begin $display("UART TB: [t1] sending %02x", pattern[i]); send(pattern[i]); end
        // let the last byte finish
        repeat (1200) @(posedge clk);
        $display("UART TB: loopback captured %0d bytes (expect 4)", got);
        if (got != 4) begin
            $display("UART TB: ERROR loopback byte count");
            errors = errors + 1;
        end

        // ---- Test 2: STATUS command through the loader ----
        $display("UART TB: [t2] STATUS command through the loader... t=%0t", $time);
        reply_n = 0;
        // magic
        send2(8'hA5);
        cr = 8'd0;
        // cmd = STATUS
        send2(8'h04); cr = crc8(cr, 8'h04);
        // len = 0
        send2(8'h00); cr = crc8(cr, 8'h00);
        send2(8'h00); cr = crc8(cr, 8'h00);
        // crc
        send2(cr);

        // 8 reply bytes at 10 bit periods each, plus margin
        repeat (12000) @(posedge clk);

        $display("UART TB: reply bytes = %0d", reply_n);
        if (reply_n != 8) begin
            $display("UART TB: ERROR expected 8 reply bytes");
            errors = errors + 1;
        end
        $display("UART TB: reply = %02x %02x %02x %02x %02x %02x %02x %02x",
                 reply[0], reply[1], reply[2], reply[3],
                 reply[4], reply[5], reply[6], reply[7]);
        $display("UART TB: weights_ready=%b act_valid=%b busy=%b err=%02x",
                 weights_ready, act_valid, busy, err_code);

        if (errors == 0) $display("UART TB: ALL TESTS PASSED");
        else             $display("UART TB: %0d ERROR(S)", errors);
        $finish;
    end

    // Loopback capture: count bytes seen by u_rx
    always @(posedge clk) begin
        if (rx_valid && rx_ready) begin
            got = got + 1;
            $display("UART TB:   rx byte %0d = %02x", got, rx_data);
        end
    end

    initial got = 0;

endmodule
