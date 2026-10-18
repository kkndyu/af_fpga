`timescale 1ns/1ps
`include "moe_params.vh"

// -----------------------------------------------------------------------------
// tb_result_readout
// -----------------------------------------------------------------------------
// Verifies the narrow readout path end to end:
//
//   load activations -> run one GEMV -> snapshot -> stream 256 lanes as
//   4 bytes each -> reassemble the 32-bit words -> compare with the golden
//   reference produced by the Python generator.
//
// Output: sim/data/readout_out.hex  (same format as sim/data/ref_out.hex)
//
// Run scripts/gen_mem.py first so sim/data/input.mem and ref_out.hex exist.
// -----------------------------------------------------------------------------
module tb_result_readout;

    reg clk;
    reg rst_n;
    reg start;

    reg                       act_wr_en;
    reg  [`H_ADDR_W-1:0]      act_wr_addr;
    reg  [`ACT_W-1:0]         act_wr_data;

    reg                       rd_start;

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

    reg [`ACT_W-1:0] input_mem [0:`H_DIM-1];
    reg [7:0]        lane_bytes [0:3];
    reg [31:0]       captured [0:`OUT_LANES-1];

    integer i;
    integer fd;
    integer bytes_seen;
    integer done_d;

    moe_proto_top dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .busy         (busy),
        .done         (done),
        .act_wr_en    (act_wr_en),
        .act_wr_addr  (act_wr_addr),
        .act_wr_data  (act_wr_data),
        .rd_start     (rd_start),
        .rd_pause     (rd_pause),
        .rd_valid     (rd_valid),
        .rd_lane      (rd_lane),
        .rd_byte      (rd_byte),
        .rd_data      (rd_data),
        .rd_busy      (rd_busy),
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

    initial begin
        rst_n       = 1'b0;
        start       = 1'b0;
        act_wr_en   = 1'b0;
        act_wr_addr = {`H_ADDR_W{1'b0}};
        act_wr_data = {`ACT_W{1'b0}};
        rd_start    = 1'b0;
        rd_pause    = 1'b0;
        done_d      = 0;

        $readmemh("sim/data/input.mem", input_mem);

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Load the activation buffer.
        for (i = 0; i < `H_DIM; i = i + 1) begin
            @(posedge clk);
            act_wr_en   <= 1'b1;
            act_wr_addr <= i[`H_ADDR_W-1:0];
            act_wr_data <= input_mem[i];
        end
        @(posedge clk);
        act_wr_en <= 1'b0;

        // Launch one GEMV.
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        wait (done == 1'b1);
        @(posedge clk);

        // The snapshot was taken on the done pulse; start streaming.
        rd_start <= 1'b1;
        @(posedge clk);
        rd_start <= 1'b0;

        // The readout emits one lane every 6 cycles: one to let the 256:1
        // lane-word read settle (it is now registered to keep the 256:1 and 4:1
        // muxes out of the same path), then four byte phases, then one spare.
        // That is 256 x 6 = 1536 cycles, plus turnaround.
        //
        // This used to be a hard-coded 1400 while the readout took 1024, and it
        // silently truncated the stream to 233 lanes once the readout changed.
        // The lane-count check below is therefore an ERROR, not a warning.
        for (i = 0; i < 3000; i = i + 1) @(posedge clk);

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
        $display("result_checksum = %08x  (expected ffffc6e2)", result_checksum);
        if (result_checksum == 32'hffffc6e2) begin
            $display("CHECKSUM MATCH");
        end else begin
            $display("CHECKSUM MISMATCH");
        end
        $display("Output: sim/data/readout_out.hex");
        $finish;
    end

endmodule
