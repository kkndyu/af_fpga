`include "moe_params.vh"

// -----------------------------------------------------------------------------
// fp4_product_gen
// -----------------------------------------------------------------------------
// Generate 16 candidate products for one activation value.
//
// This is a bring-up integer approximation of the intended FP4/BF16 product
// generator.  It does NOT instantiate multipliers.  It forms shifts/adds/negates
// of activation A and packs them into prod16_flat.
//
// Packing convention:
//   prod16_flat[i*PROD_W +: PROD_W] is candidate product for FP4 code i.
// -----------------------------------------------------------------------------
module fp4_product_gen #(
    parameter ACT_W  = `ACT_W,
    parameter PROD_W = `PROD_W
)(
    input  signed [ACT_W-1:0]              a,
    output        [(`FP4_CODES*PROD_W)-1:0] prod16_flat
);

    wire signed [PROD_W-1:0] a_ext;
    wire signed [PROD_W-1:0] a_x_0;
    wire signed [PROD_W-1:0] a_x_quarter;
    wire signed [PROD_W-1:0] a_x_half;
    wire signed [PROD_W-1:0] a_x_1;
    wire signed [PROD_W-1:0] a_x_1p5;
    wire signed [PROD_W-1:0] a_x_2;
    wire signed [PROD_W-1:0] a_x_4;

    assign a_ext       = {{(PROD_W-ACT_W){a[ACT_W-1]}}, a};
    assign a_x_0       = {PROD_W{1'b0}};
    assign a_x_quarter = a_ext >>> 2;
    assign a_x_half    = a_ext >>> 1;
    assign a_x_1       = a_ext;
    assign a_x_1p5     = a_ext + (a_ext >>> 1);
    assign a_x_2       = a_ext <<< 1;
    assign a_x_4       = a_ext <<< 2;

    // Positive / zero candidates.
    assign prod16_flat[ 0*PROD_W +: PROD_W] = a_x_0;
    assign prod16_flat[ 1*PROD_W +: PROD_W] = a_x_half;
    assign prod16_flat[ 2*PROD_W +: PROD_W] = a_x_1;
    assign prod16_flat[ 3*PROD_W +: PROD_W] = a_x_1p5;
    assign prod16_flat[ 4*PROD_W +: PROD_W] = a_x_2;
    assign prod16_flat[ 5*PROD_W +: PROD_W] = a_x_4;
    assign prod16_flat[ 6*PROD_W +: PROD_W] = a_x_quarter;
    assign prod16_flat[ 7*PROD_W +: PROD_W] = a_x_0;

    // Negative / zero candidates.
    assign prod16_flat[ 8*PROD_W +: PROD_W] = a_x_0;
    assign prod16_flat[ 9*PROD_W +: PROD_W] = -a_x_half;
    assign prod16_flat[10*PROD_W +: PROD_W] = -a_x_1;
    assign prod16_flat[11*PROD_W +: PROD_W] = -a_x_1p5;
    assign prod16_flat[12*PROD_W +: PROD_W] = -a_x_2;
    assign prod16_flat[13*PROD_W +: PROD_W] = -a_x_4;
    assign prod16_flat[14*PROD_W +: PROD_W] = -a_x_quarter;
    assign prod16_flat[15*PROD_W +: PROD_W] = a_x_0;

endmodule
