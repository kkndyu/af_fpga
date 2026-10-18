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
//
// V2: the weight load port is passed straight through.  When the up and down
// stages are added, this is the module that will get an expert/layer address
// decoder in front of the four banks - which is why the port is described in
// terms of a region rather than a bank.
// -----------------------------------------------------------------------------
module expert_engine (
    input                       clk,
    input                       rst_n,
    input                       start,
    output                      busy,
    output                      done,

    // Weight load port, passed through to gemv_engine.
    input                       w_wr_en,
    input      [1:0]            w_wr_region,
    input      [`H_ADDR_W-1:0]  w_wr_addr,
    input      [`REGION_WCODE_W-1:0] w_wr_data,

    input                       act_wr_en,
    input      [`H_ADDR_W-1:0]  act_wr_addr,
    input      [`ACT_W-1:0]     act_wr_data,

    output     [`OUT_ACC_W-1:0] expert_out_flat
);

    gemv_engine #(
        .K_LEN(`H_DIM),
        .K_ADDR_W(`H_ADDR_W)
    ) u_gate_gemv (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .w_wr_en(w_wr_en),
        .w_wr_region(w_wr_region),
        .w_wr_addr(w_wr_addr),
        .w_wr_data(w_wr_data),
        .act_wr_en(act_wr_en),
        .act_wr_addr(act_wr_addr),
        .act_wr_data(act_wr_data),
        .acc_flat(expert_out_flat)
    );

endmodule
