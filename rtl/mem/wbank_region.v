`include "moe_params.vh"

// -----------------------------------------------------------------------------
// wbank_region
// -----------------------------------------------------------------------------
// Region-local weight bank.  One read returns REGION_LANES 4-bit FP4 codes.
// For REGION_LANES=64, read width is 256 bits.
//
// Memory initialization uses $readmemh.  For synthesis in Vivado, this normally
// maps to initialized block RAM when the memory is inferred correctly.
// -----------------------------------------------------------------------------
module wbank_region #(
    parameter DEPTH     = `H_DIM,
    parameter ADDR_W    = `H_ADDR_W,
    parameter DATA_W    = `REGION_WCODE_W,
    parameter INIT_FILE = ""
)(
    input                    clk,
    input                    rd_en,
    input      [ADDR_W-1:0]  rd_addr,
    output reg [DATA_W-1:0]  rd_data
);

    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clk) begin
        if (rd_en) begin
            rd_data <= mem[rd_addr];
        end
    end

endmodule
