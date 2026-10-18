`include "moe_params.vh"

// -----------------------------------------------------------------------------
// vec_buffer
// -----------------------------------------------------------------------------
// Generic vector buffer for intermediate/output vectors.  First-version helper
// module; expert_engine can use it later for gate/up/down data staging.
// -----------------------------------------------------------------------------
module vec_buffer #(
    parameter DEPTH  = `H_DIM,
    parameter ADDR_W = `H_ADDR_W,
    parameter DATA_W = `ACC_W
)(
    input                    clk,
    input                    wr_en,
    input      [ADDR_W-1:0]  wr_addr,
    input      [DATA_W-1:0]  wr_data,
    input                    rd_en,
    input      [ADDR_W-1:0]  rd_addr,
    output reg [DATA_W-1:0]  rd_data
);

    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
        if (rd_en) begin
            rd_data <= mem[rd_addr];
        end
    end

endmodule
