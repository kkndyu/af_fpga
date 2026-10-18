`include "moe_params.vh"

// -----------------------------------------------------------------------------
// wbank_region
// -----------------------------------------------------------------------------
// Region-local weight bank.  One read returns REGION_LANES 4-bit FP4 codes, so
// for REGION_LANES=64 the read width is 256 bits.
//
// V2: the bank is WRITABLE at runtime and has NO initial contents.
//
// Until V2 the contents came from $readmemh inside an initial block, which the
// synthesiser turns into the RAMB36E1 INIT_* attributes - in other words the
// weights were baked into the bitstream, and changing one test vector meant a
// 35-minute rebuild plus a reflash.  That is not how an accelerator works, so
// the initial block is gone and the bank configures as all zeros.  Something
// outside has to fill it.
//
// Why a whole 256-bit row per write rather than 32-bit slices:
//
//   The natural implementation is eight RAMB36E1 in 1024x36 mode with 32 bits
//   used out of each.  Writing one 32-bit slice would look like
//
//       mem[addr][slice*32 +: 32] <= data
//
//   which forces the synthesiser to infer a byte/slice-enabled RAM with no
//   guarantee of success.  A full-width write infers the plain simple dual-port
//   RAM - one write port, one read port, independent addresses - and RAMB36E1 is
//   exactly that, so the write port costs nothing.  The loader buffers 32 bytes
//   and commits one row instead of eight partial writes.
//
// Conflict note: a write and a read of the same address in the same cycle is
// undefined here (write-first/read-first depends on inference).  The control
// FSM keeps loading and computing in separate phases, so this cannot happen.
// -----------------------------------------------------------------------------
module wbank_region #(
    parameter DEPTH  = `H_DIM,
    parameter ADDR_W = `H_ADDR_W,
    parameter DATA_W = `REGION_WCODE_W
)(
    input                    clk,

    // Runtime load port (V2).
    input                    wr_en,
    input      [ADDR_W-1:0]  wr_addr,
    input      [DATA_W-1:0]  wr_data,

    // Compute read port.
    input                    rd_en,
    input      [ADDR_W-1:0]  rd_addr,
    output reg [DATA_W-1:0]  rd_data
);

    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

    // No initial block, deliberately.  See the header.
    always @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
        if (rd_en) rd_data <= mem[rd_addr];
    end

endmodule
