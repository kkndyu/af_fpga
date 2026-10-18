`ifndef MOE_PARAMS_VH
`define MOE_PARAMS_VH

// -----------------------------------------------------------------------------
// MoE FPGA prototype global parameters
// Pure Verilog-2001 version.  No SystemVerilog package/logic/enum/array ports.
// -----------------------------------------------------------------------------

`define H_DIM          1024
`define E_DIM          256

`define OUT_LANES      256
`define REGION_LANES   64
`define NUM_REGIONS    4

`define WCODE_W        4
`define ACT_W          16
`define PROD_W         24
`define ACC_W          32
`define FP4_CODES      16

`define H_ADDR_W       10   // log2(1024)
`define E_ADDR_W       8    // log2(256)

`define REGION_WCODE_W (`REGION_LANES * `WCODE_W)
`define PROD16_W       (`FP4_CODES * `PROD_W)
`define REGION_ACC_W   (`REGION_LANES * `ACC_W)
`define OUT_ACC_W      (`OUT_LANES * `ACC_W)

// Stage encoding.  Kept as macros instead of SystemVerilog enum.
`define STAGE_GATE     2'd0
`define STAGE_UP       2'd1
`define STAGE_DOWN     2'd2

`endif
