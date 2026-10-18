`include "moe_params.vh"

// -----------------------------------------------------------------------------
// fp4_select
// -----------------------------------------------------------------------------
// Select one candidate product from a flattened prod16 bus according to a 4-bit
// FP4 weight code.  This is synthesized as a PROD_W-bit wide 16:1 mux, with
// constant/simplified inputs optimized by the synthesis tool.
// -----------------------------------------------------------------------------
module fp4_select #(
    parameter PROD_W  = `PROD_W,
    parameter WCODE_W = `WCODE_W
)(
    input      [WCODE_W-1:0]                 wcode,
    input      [(`FP4_CODES*PROD_W)-1:0]     prod16_flat,
    output reg signed [PROD_W-1:0]           selected_prod
);

    always @* begin
        case (wcode)
            4'h0: selected_prod = prod16_flat[ 0*PROD_W +: PROD_W];
            4'h1: selected_prod = prod16_flat[ 1*PROD_W +: PROD_W];
            4'h2: selected_prod = prod16_flat[ 2*PROD_W +: PROD_W];
            4'h3: selected_prod = prod16_flat[ 3*PROD_W +: PROD_W];
            4'h4: selected_prod = prod16_flat[ 4*PROD_W +: PROD_W];
            4'h5: selected_prod = prod16_flat[ 5*PROD_W +: PROD_W];
            4'h6: selected_prod = prod16_flat[ 6*PROD_W +: PROD_W];
            4'h7: selected_prod = prod16_flat[ 7*PROD_W +: PROD_W];
            4'h8: selected_prod = prod16_flat[ 8*PROD_W +: PROD_W];
            4'h9: selected_prod = prod16_flat[ 9*PROD_W +: PROD_W];
            4'ha: selected_prod = prod16_flat[10*PROD_W +: PROD_W];
            4'hb: selected_prod = prod16_flat[11*PROD_W +: PROD_W];
            4'hc: selected_prod = prod16_flat[12*PROD_W +: PROD_W];
            4'hd: selected_prod = prod16_flat[13*PROD_W +: PROD_W];
            4'he: selected_prod = prod16_flat[14*PROD_W +: PROD_W];
            4'hf: selected_prod = prod16_flat[15*PROD_W +: PROD_W];
            default: selected_prod = {PROD_W{1'b0}};
        endcase
    end

endmodule
