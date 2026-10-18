`include "moe_params.vh"

// -----------------------------------------------------------------------------
// expert_engine
// -----------------------------------------------------------------------------
// First-version expert sequencer wrapper.
//
// This Verilog version keeps the implementation deliberately simple: it launches
// one gate-like GEMV engine and reports completion.  The file is kept as a stable
// integration point for the later full sequence:
//
//   gate GEMV -> up GEMV -> activation/mul -> down GEMV -> expert output
//
// In other words, gemv_engine is the implemented datapath; expert_engine is the
// place where the multi-stage expert schedule will be added.
// -----------------------------------------------------------------------------
module expert_engine #(
    parameter INIT_R0 = "mem_init/expert0/gate_r0.mem",
    parameter INIT_R1 = "mem_init/expert0/gate_r1.mem",
    parameter INIT_R2 = "mem_init/expert0/gate_r2.mem",
    parameter INIT_R3 = "mem_init/expert0/gate_r3.mem"
)(
    input                       clk,
    input                       rst_n,
    input                       start,
    output                      busy,
    output                      done,

    input                       act_wr_en,
    input      [`H_ADDR_W-1:0]  act_wr_addr,
    input      [`ACT_W-1:0]     act_wr_data,

    output     [`OUT_ACC_W-1:0] expert_out_flat
);

    gemv_engine #(
        .K_LEN(`H_DIM),
        .K_ADDR_W(`H_ADDR_W),
        .INIT_R0(INIT_R0),
        .INIT_R1(INIT_R1),
        .INIT_R2(INIT_R2),
        .INIT_R3(INIT_R3)
    ) u_gate_gemv (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .act_wr_en(act_wr_en),
        .act_wr_addr(act_wr_addr),
        .act_wr_data(act_wr_data),
        .acc_flat(expert_out_flat)
    );

endmodule
