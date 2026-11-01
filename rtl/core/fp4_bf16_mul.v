// Unscaled BF16 x E2M1 multiplication. Shared candidate generation and separate
// exponent/mantissa outputs are available directly in fp4_bf16_product_gen for
// a regional implementation; this wrapper is useful for arithmetic regression.
module fp4_bf16_mul (
    input [15:0] activation,
    input [3:0] weight,
    output [31:0] result
);
    wire [95:0] candidates;
    wire signed [10:0] exponent;
    wire activation_sign, activation_inf, activation_nan;
    wire [11:0] magnitude = candidates[weight[2:0]*12 +: 12];
    fp4_bf16_product_gen u_gen (
        .activation(activation), .magnitude_flat(candidates), .product_exp(exponent),
        .activation_sign(activation_sign), .activation_inf(activation_inf), .activation_nan(activation_nan)
    );
    fp32_pack #(.MANT_W(12)) u_pack (
        .magnitude(magnitude), .exponent(exponent), .sign(activation_sign ^ weight[3]),
        .is_inf(activation_inf && weight[2:0] != 0),
        .is_nan(activation_nan || (activation_inf && weight[2:0] == 0)), .result(result)
    );
endmodule
