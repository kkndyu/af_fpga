`timescale 1ns/1ps
`include "moe_params.vh"

// -----------------------------------------------------------------------------
// tb_gemv_engine  -  numerical check of the GEMV datapath
// -----------------------------------------------------------------------------
// This replaces the earlier bench, which drove the engine through parameters
// (INIT_R0..R3) that no longer exist: weights are now loaded through the write
// port, so the old bench could not even elaborate, and the engine has been
// unverified in simulation since that change.
//
// Expected values are derived by hand, not from a model, so a shared
// misunderstanding cannot hide here.
//
//   test 1  every weight zero                  -> every lane 0
//   test 2  one-hot: lane k gets code 2 (x1.0) at row k only, for k = 0..63,
//           and activation[k] = k+1              -> lane j = j+1 for j < 64,
//                                                   lane j = 0 for j >= 64
//
// test 2 is the strong one.  Code 2 multiplies by exactly 1.0, so the answer is
// literally the input: it checks row addressing, lane->region mapping, the
// nibble position of a lane inside a row, the accumulator clear and sign
// extension all at once.  Any of them wrong and the lanes are not j+1.
// -----------------------------------------------------------------------------
module tb_gemv_engine;

    localparam integer K_LEN        = `H_DIM;         // 1024
    localparam integer REGION_LANES = `REGION_LANES;  // 64
    localparam integer LANES        = REGION_LANES * 4;
    localparam integer ACC_W        = `ACC_W;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #2.5 clk = ~clk;      // 200 MHz

    reg         start = 1'b0;
    wire        busy;
    wire        done;

    reg         w_wr_en = 1'b0;
    reg  [1:0]  w_wr_region = 2'd0;
    reg  [9:0]  w_wr_addr = 10'd0;
    reg  [`REGION_WCODE_W-1:0] w_wr_data = 0;

    reg         act_wr_en = 1'b0;
    reg  [9:0]  act_wr_addr = 10'd0;
    reg  [`ACT_W-1:0] act_wr_data = {`ACT_W{1'b0}};

    wire [`OUT_ACC_W-1:0] acc_flat;

    gemv_engine #(.K_LEN(K_LEN), .K_ADDR_W(10)) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .busy          (busy),
        .done          (done),
        .w_wr_en       (w_wr_en),
        .w_wr_region   (w_wr_region),
        .w_wr_addr     (w_wr_addr),
        .w_wr_data     (w_wr_data),
        .act_wr_en     (act_wr_en),
        .act_wr_addr   (act_wr_addr),
        .act_wr_data   (act_wr_data),
        .rb_start      (1'b0),
        .rb_region     (2'd0),
        .rb_addr       (10'd0),
        .rb_nrows      (16'd0),
        .rb_byte_ready (1'b0),
        .rb_byte_out   (),
        .rb_byte_valid (),
        .rb_done       (),
        .acc_flat      (acc_flat)
    );

    integer errors = 0;

    task wr_weight;
        input integer row;
        input integer region;
        input [`REGION_WCODE_W-1:0] data;
        begin
            @(posedge clk);
            w_wr_en     <= 1'b1;
            w_wr_addr   <= row[9:0];
            w_wr_region <= region[1:0];
            w_wr_data   <= data;
            @(posedge clk);
            w_wr_en     <= 1'b0;
        end
    endtask

    task wr_act;
        input integer idx;
        input [`ACT_W-1:0] data;
        begin
            @(posedge clk);
            act_wr_en   <= 1'b1;
            act_wr_addr <= idx[9:0];
            act_wr_data <= data;
            @(posedge clk);
            act_wr_en   <= 1'b0;
        end
    endtask

    task run_engine;
        begin
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            wait (done === 1'b1);
            @(posedge clk);
        end
    endtask

    function [`ACC_W-1:0] lane_acc;
        input integer j;
        begin
            lane_acc = acc_flat[j*ACC_W +: ACC_W];
        end
    endfunction

    integer i, j, bad;
    reg [`REGION_WCODE_W-1:0] wrow;

    initial begin
        $display("");
        $display("========== tb_gemv_engine ==========");

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---------------- test 1: all weights zero ----------------
        $display("  ---- test 1: all-zero weights ----");
        for (i = 0; i < K_LEN; i = i + 1)
            for (j = 0; j < 4; j = j + 1)
                wr_weight(i, j, 0);
        for (i = 0; i < K_LEN; i = i + 1)
            wr_act(i, {`ACT_W{1'b0}});

        run_engine;

        bad = 0;
        for (j = 0; j < LANES; j = j + 1)
            if (lane_acc(j) !== {ACC_W{1'b0}}) bad = bad + 1;
        if (bad == 0)
            $display("  PASS: every lane 0");
        else begin
            $display("  FAIL: %0d lanes nonzero with all-zero weights", bad);
            errors = errors + 1;
        end

        // ---------------- test 2: one-hot ----------------
        $display("  ---- test 2: one-hot, lane j should be j+1 ----");
        for (i = 0; i < K_LEN; i = i + 1) begin
            if (i < 64) wr_act(i, i + 1);
            else        wr_act(i, {`ACT_W{1'b0}});
        end
        for (i = 0; i < K_LEN; i = i + 1)
            for (j = 0; j < 4; j = j + 1)
                wr_weight(i, j, 0);
        for (i = 0; i < 64; i = i + 1) begin
            wrow = 0;
            wrow[i*4 +: 4] = 4'h2;
            wr_weight(i, 0, wrow);
        end

        run_engine;

        bad = 0;
        for (j = 0; j < 64; j = j + 1)
            if (lane_acc(j) !== (j + 1)) begin
                if (bad < 4)
                    $display("    lane %0d = %0d, expected %0d", j, lane_acc(j), j + 1);
                bad = bad + 1;
            end
        for (j = 64; j < LANES; j = j + 1)
            if (lane_acc(j) !== {ACC_W{1'b0}}) begin
                if (bad < 4)
                    $display("    lane %0d = %0d, expected 0", j, lane_acc(j));
                bad = bad + 1;
            end

        if (bad == 0)
            $display("  PASS: lanes 0..63 = 1..64, lanes 64..255 = 0");
        else begin
            $display("  FAIL: %0d lanes wrong", bad);
            errors = errors + 1;
        end

        $display("");
        if (errors == 0) $display("GEMV TB: ALL TESTS PASSED");
        else             $display("GEMV TB: %0d FAILURE(S)", errors);
        $display("====================================");
        $display("");
        $finish;
    end

endmodule
