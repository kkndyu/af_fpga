`timescale 1ns/1ps
`include "moe_params.vh"

// -----------------------------------------------------------------------------
// tb_gemv_engine
// -----------------------------------------------------------------------------
// Basic simulation testbench for one gate GEMV stage.
// Run scripts/gen_mem.py first to generate input.mem, reference, and weight banks.
// -----------------------------------------------------------------------------
module tb_gemv_engine;

    reg clk;
    reg rst_n;
    reg start;
    wire busy;
    wire done;

    reg                       act_wr_en;
    reg  [`H_ADDR_W-1:0]      act_wr_addr;
    reg  [`ACT_W-1:0]         act_wr_data;
    wire [`OUT_ACC_W-1:0]     acc_flat;

    reg [`ACT_W-1:0] input_mem [0:`H_DIM-1];
    integer i;
    integer fd;

    gemv_engine #(
        .K_LEN(`H_DIM),
        .K_ADDR_W(`H_ADDR_W),
        .INIT_R0("mem_init/expert0/gate_r0.mem"),
        .INIT_R1("mem_init/expert0/gate_r1.mem"),
        .INIT_R2("mem_init/expert0/gate_r2.mem"),
        .INIT_R3("mem_init/expert0/gate_r3.mem")
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .act_wr_en(act_wr_en),
        .act_wr_addr(act_wr_addr),
        .act_wr_data(act_wr_data),
        .acc_flat(acc_flat)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n       = 1'b0;
        start       = 1'b0;
        act_wr_en   = 1'b0;
        act_wr_addr = {`H_ADDR_W{1'b0}};
        act_wr_data = {`ACT_W{1'b0}};

        $readmemh("sim/data/input.mem", input_mem);

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Load activation buffer.
        for (i = 0; i < `H_DIM; i = i + 1) begin
            @(posedge clk);
            act_wr_en   <= 1'b1;
            act_wr_addr <= i[`H_ADDR_W-1:0];
            act_wr_data <= input_mem[i];
        end
        @(posedge clk);
        act_wr_en <= 1'b0;

        // Start GEMV.
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        wait(done == 1'b1);
        @(posedge clk);

        fd = $fopen("sim/data/rtl_out.hex", "w");
        for (i = 0; i < `OUT_LANES; i = i + 1) begin
            $fwrite(fd, "%08x\n", acc_flat[i*`ACC_W +: `ACC_W]);
        end
        $fclose(fd);

        $display("tb_gemv_engine finished. Output: sim/data/rtl_out.hex");
        $finish;
    end

endmodule
