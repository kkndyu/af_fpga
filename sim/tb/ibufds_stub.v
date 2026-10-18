`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// ibufds_stub - simulation-only model of the Xilinx IBUFDS primitive
// -----------------------------------------------------------------------------
// moe_proto_board.v instantiates IBUFDS to turn the board's differential clock
// pair into a single-ended clock.  IBUFDS lives in the Xilinx unisim library,
// which plain xsim elaboration of RTL does not pull in, so simulating the board
// top fails with "Module <IBUFDS> not found".
//
// For synthesis this file must NOT be compiled - Vivado binds the real
// primitive automatically and this would collide with it.  It exists purely so
// the board-level testbench can run.
//
// The model is intentionally trivial: the board drives sys_clk_n as the
// complement of sys_clk_p, so the buffered output is just the P side.
// -----------------------------------------------------------------------------
module IBUFDS (
    output O,
    input  I,
    input  IB
);

    assign O = I;

    // Keep IB referenced so the port is not left dangling, without letting it
    // affect the result.
    wire unused_ib = IB;

endmodule

// -----------------------------------------------------------------------------
// BUFG stub - simulation-only model of the Xilinx global clock buffer
// -----------------------------------------------------------------------------
// moe_proto_board uses a BUFG to put its divided engine clock on a global net.
// BUFG also lives in unisims, so plain RTL elaboration needs this stub for the
// same reason IBUFDS does.  For synthesis, do NOT compile this file.
// -----------------------------------------------------------------------------
module BUFG (
    output O,
    input  I
);

    assign O = I;

endmodule
