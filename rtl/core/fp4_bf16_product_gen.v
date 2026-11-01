`include "moe_params.vh"

// Exact finite BF16 x E2M1 candidates. Candidate i is an unsigned integer
// significand times 2**product_exp; sign is activation_sign XOR weight[3].
// E2M1 magnitudes are {0, 0.5, 1, 1.5, 2, 3, 4, 6}, including signed zero.
// Keeping the exponent separate avoids rounding the 0.5 product to an integer.
module fp4_bf16_product_gen (
    input [15:0] activation,
    output [95:0] magnitude_flat,
    output signed [10:0] product_exp,
    output activation_sign,
    output activation_inf,
    output activation_nan
);
    wire [7:0] exponent = activation[14:7];
    wire [7:0] significand = {(|exponent), activation[6:0]};
    wire [11:0] m = {4'd0, significand};
    assign activation_sign = activation[15];
    assign activation_inf = (&exponent) && !(|activation[6:0]);
    assign activation_nan = (&exponent) && (|activation[6:0]);
    // BF16 finite value = significand * 2**(effective_exponent - 134).
    // The integer E2M1 coefficients below are twice their numerical values.
    assign product_exp = $signed({3'd0, (exponent == 0 ? 8'd1 : exponent)}) - 11'sd135;
    assign magnitude_flat[0*12 +: 12] = 12'd0;
    assign magnitude_flat[1*12 +: 12] = m;
    assign magnitude_flat[2*12 +: 12] = m << 1;
    assign magnitude_flat[3*12 +: 12] = m + (m << 1);
    assign magnitude_flat[4*12 +: 12] = m << 2;
    assign magnitude_flat[5*12 +: 12] = (m << 1) + (m << 2);
    assign magnitude_flat[6*12 +: 12] = m << 3;
    assign magnitude_flat[7*12 +: 12] = (m << 2) + (m << 3);
endmodule
