`timescale 1ns/1ps
`include "moe_params.vh"

// -----------------------------------------------------------------------------
// tb_result_readout
// -----------------------------------------------------------------------------
// End-to-end V2 test: nothing is baked into the memories, everything is loaded
// through the runtime write ports.
//
//   1. reset, run one GEMV with nothing loaded
//      -> every lane must be 0.  This is the proof that the weight and
//         activation BRAMs configure empty.  If any $readmemh had survived,
//         this check would fail instead of silently passing.
//   2. load the weights through w_wr_* (4096 rows: 4 regions x 1024)
//   3. load the activations through act_wr_*
//   4. run one GEMV, stream all 256 lanes out, compare against the golden
//      reference produced by the Python generator
//
// Output: sim/data/readout_out.hex  (same format as sim/data/ref_out.hex)
//
// The weight files are read here, in the testbench, exactly as a host program
// would read them before pushing them down a serial link.  The design under test
// has no idea they exist.
// -----------------------------------------------------------------------------
module tb_result_readout;

    reg clk;
    reg rst_n;
    reg start;

    // Weight load port.
    reg                       w_wr_en;
    reg  [1:0]                w_wr_region;
    reg  [`H_ADDR_W-1:0]      w_wr_addr;
    reg  [`REGION_WCODE_W-1:0] w_wr_data;

    reg                       act_wr_en;
    reg  [`H_ADDR_W-1:0]      act_wr_addr;
    reg  [`ACT_W-1:0]         act_wr_data;

    reg                       rd_start;
    reg  [`E_ADDR_W-1:0]      rd_start_lane;

    // Readout throttle.  Must be driven: leaving it unconnected makes it float,
    // and "if (!rd_pause)" then never evaluates true, so the readout never
    // advances and the testbench captures zero lanes.  That is exactly what
    // happened when the port was added.
    reg                       rd_pause;

    wire                      busy;
    wire                      done;
    wire                      rd_valid;
    wire [`E_ADDR_W-1:0]      rd_lane;
    wire [1:0]                rd_byte;
    wire [7:0]                rd_data;
    wire                      rd_busy;
    wire [31:0]               result_checksum;

    // Host-side copies of the data files.
    reg [`ACT_W-1:0]     input_mem [0:`H_DIM-1];
    reg [`REGION_WCODE_W-1:0] w_mem0 [0:`H_DIM-1];
    reg [`REGION_WCODE_W-1:0] w_mem1 [0:`H_DIM-1];
    reg [`REGION_WCODE_W-1:0] w_mem2 [0:`H_DIM-1];
    reg [`REGION_WCODE_W-1:0] w_mem3 [0:`H_DIM-1];

    reg [7:0]        lane_bytes [0:3];
    reg [31:0]       captured [0:`OUT_LANES-1];

    integer i;
    integer b;
    integer fd;
    integer bytes_seen;
    integer nonzero_before_load;

    moe_proto_top dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .busy           (busy),
        .done           (done),
        .w_wr_en        (w_wr_en),
        .w_wr_region    (w_wr_region),
        .w_wr_addr      (w_wr_addr),
        .w_wr_data      (w_wr_data),
        .act_wr_en      (act_wr_en),
        .act_wr_addr    (act_wr_addr),
        .act_wr_data    (act_wr_data),
        .rd_start       (rd_start),
        .rd_start_lane  (rd_start_lane),
        .rd_pause       (rd_pause),
        .rd_valid       (rd_valid),
        .rd_lane        (rd_lane),
        .rd_byte        (rd_byte),
        .rd_data        (rd_data),
        .rd_busy        (rd_busy),
        .result_checksum(result_checksum)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Reassemble every 32-bit lane word from the byte stream.
    initial begin
        for (i = 0; i < `OUT_LANES; i = i + 1) captured[i] = 32'd0;
        for (i = 0; i < 4; i = i + 1) lane_bytes[i] = 8'd0;
        bytes_seen = 0;
    end

    always @(posedge clk) begin
        if (rd_valid) begin
            lane_bytes[rd_byte] <= rd_data;
            if (rd_byte == 2'd3) begin
                captured[rd_lane] <= {rd_data, lane_bytes[2], lane_bytes[1], lane_bytes[0]};
                bytes_seen <= bytes_seen + 1;
            end
        end
    end

    // One GEMV plus a full readout.  The readout emits one lane every 6 cycles
    // (one for the 64:1 selector to settle, four byte phases, one spare), so a
    // full sweep is 256 x 6 = 1536 cycles.  The wait below is deliberately
    // generous; the lane-count check is an ERROR, not a warning, because a
    // truncated stream used to pass silently.
    task run_and_read;
        begin
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;

            wait (done == 1'b1);
            @(posedge clk);

            rd_start_lane <= {`E_ADDR_W{1'b0}};
            rd_start      <= 1'b1;
            @(posedge clk);
            rd_start      <= 1'b0;

            for (i = 0; i < 3000; i = i + 1) @(posedge clk);
        end
    endtask

    initial begin
        rst_n         = 1'b0;
        start         = 1'b0;
        w_wr_en       = 1'b0;
        w_wr_region   = 2'd0;
        w_wr_addr     = {`H_ADDR_W{1'b0}};
        w_wr_data     = {`REGION_WCODE_W{1'b0}};
        act_wr_en     = 1'b0;
        act_wr_addr   = {`H_ADDR_W{1'b0}};
        act_wr_data   = {`ACT_W{1'b0}};
        rd_start      = 1'b0;
        rd_start_lane = {`E_ADDR_W{1'b0}};
        rd_pause      = 1'b0;

        // Host side: read the data files that a host program would send.
        $readmemh("sim/data/input.mem", input_mem);
        $readmemh("mem_init/expert0/gate_r0.mem", w_mem0);
        $readmemh("mem_init/expert0/gate_r1.mem", w_mem1);
        $readmemh("mem_init/expert0/gate_r2.mem", w_mem2);
        $readmemh("mem_init/expert0/gate_r3.mem", w_mem3);

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ----------------------------------------------------------------
        // Step 1: prove the memories configure empty.
        // ----------------------------------------------------------------
        run_and_read;

        nonzero_before_load = 0;
        for (i = 0; i < `OUT_LANES; i = i + 1) begin
            if (captured[i] !== 32'd0) nonzero_before_load = nonzero_before_load + 1;
        end
        if (bytes_seen != `OUT_LANES) begin
            $display("tb_result_readout: ERROR pre-load lane count = %0d", bytes_seen);
        end
        if (nonzero_before_load == 0) begin
            $display("MEMORIES START EMPTY  (all %0d lanes were 0 before loading)", `OUT_LANES);
        end else begin
            $display("ERROR: %0d lanes were non-zero BEFORE loading - something is still baked in",
                     nonzero_before_load);
        end

        // ----------------------------------------------------------------
        // Step 2: load the weights, exactly the way a loader would.
        // ----------------------------------------------------------------
        for (i = 0; i < `H_DIM; i = i + 1) begin
            for (b = 0; b < 4; b = b + 1) begin
                @(posedge clk);
                w_wr_en     <= 1'b1;
                w_wr_region <= b[1:0];
                w_wr_addr   <= i[`H_ADDR_W-1:0];
                case (b)
                    0: w_wr_data <= w_mem0[i];
                    1: w_wr_data <= w_mem1[i];
                    2: w_wr_data <= w_mem2[i];
                    default: w_wr_data <= w_mem3[i];
                endcase
            end
        end
        @(posedge clk);
        w_wr_en <= 1'b0;

        // ----------------------------------------------------------------
        // Step 3: load the activations.
        // ----------------------------------------------------------------
        for (i = 0; i < `H_DIM; i = i + 1) begin
            @(posedge clk);
            act_wr_en   <= 1'b1;
            act_wr_addr <= i[`H_ADDR_W-1:0];
            act_wr_data <= input_mem[i];
        end
        @(posedge clk);
        act_wr_en <= 1'b0;

        // ----------------------------------------------------------------
        // Step 4: run and check.
        // ----------------------------------------------------------------
        bytes_seen = 0;
        for (i = 0; i < `OUT_LANES; i = i + 1) captured[i] = 32'd0;

        run_and_read;

        if (bytes_seen != `OUT_LANES) begin
            $display("tb_result_readout: ERROR lane count = %0d (expected %0d)",
                     bytes_seen, `OUT_LANES);
        end

        fd = $fopen("sim/data/readout_out.hex", "w");
        for (i = 0; i < `OUT_LANES; i = i + 1) begin
            $fwrite(fd, "%08x\n", captured[i]);
        end
        $fclose(fd);

        $display("tb_result_readout finished. lanes captured = %0d", bytes_seen);
        $display("result_checksum = %08x  (expected ffffc6e2, plus 0 from the pre-load run)",
                 result_checksum);
        if (result_checksum == 32'hffffc6e2) begin
            $display("CHECKSUM MATCH");
        end else begin
            $display("CHECKSUM MISMATCH");
        end
        $display("Output: sim/data/readout_out.hex");
        $finish;
    end

endmodule
