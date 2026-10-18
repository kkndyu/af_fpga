`include "moe_params.vh"

// -----------------------------------------------------------------------------
// act_buffer
// -----------------------------------------------------------------------------
// Simple activation vector buffer with one write port and one synchronous read
// port.  Used by gemv_engine to read x[k].
// -----------------------------------------------------------------------------
module act_buffer #(
    parameter DEPTH  = `H_DIM,
    parameter ADDR_W = `H_ADDR_W,
    parameter DATA_W = `ACT_W
)(
    input                         clk,
    input                         wr_en,
    input      [ADDR_W-1:0]       wr_addr,
    input      [DATA_W-1:0]       wr_data,
    input                         rd_en,
    input      [ADDR_W-1:0]       rd_addr,
    output reg signed [DATA_W-1:0] rd_data
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
