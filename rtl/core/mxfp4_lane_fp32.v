`include "moe_params.vh"

// -----------------------------------------------------------------------------
// mxfp4_lane_fp32 - BF16 x E2M1 x E8M0 lane with binary32 accumulation
// -----------------------------------------------------------------------------
// Selected by MOE_MXFP4_FP32 in place of mxfp4_lane.  Same ports and the same
// prepare/step/finish handshake, so the region and engine need no protocol
// change; only the accumulator representation differs.
//
// The exact lane keeps 544 bits per accumulator and adds with a rotating 32-bit
// carry chain over 17 cycles, so 1024 terms can be summed with no intermediate
// rounding.  That is 69,632 flip-flops across 128 lanes.
//
// Here each product is packed to binary32 and accumulated with fp32_add, which
// rounds to nearest even on every addition.  This is the tensor-core convention:
// low precision products, single precision accumulation.
//
// What changes numerically, deliberately:
//   - Each addition rounds, so the sum depends on the order of the terms and
//     carries ordinary binary32 addition error.
//   - A product above the binary32 range becomes infinity, and one below the
//     subnormal range flushes to signed zero.  The exact lane carries both to
//     the end and rounds once.
//   - Products are still exact before accumulation: the significand is at most
//     8 bits from BF16 times {1.0, 1.5} from E2M1, so at most 9 bits, well inside
//     binary32's 24.
//
// Throughput: one addition per row instead of seventeen, so the engine can
// shorten its ACC phase from 17 to 2 cycles.
//
// fp32_add is combinational and its header states it does not claim a one-cycle
// 200 MHz path.  The feedback here is accumulator -> fp32_add -> accumulator, so
// if implementation reports this path failing, fp32_add needs pipeline stages
// and this lane must then take two or more cycles per addition.
// -----------------------------------------------------------------------------
module mxfp4_lane_fp32 (
    input clk, rst_n,
    input clear, capture, prepare, abs_init, step, abs_mode, finish,
    input [4:0] word_phase,
    input [95:0] magnitude_flat,
    input [7:0] activation_exp,
    input activation_sign, activation_inf, activation_nan,
    input [3:0] weight,
    input [7:0] scale,
    output reg [31:0] result,
    output reg result_valid
);
    wire [11:0] magnitude = magnitude_flat[weight[2:0]*12 +: 12];
    wire        negative  = activation_sign ^ weight[3];

    // fp4_bf16_product_gen offsets its candidate exponents by 135 for an
    // unscaled product; the E8M0 block scale contributes exponent scale-127.
    wire [7:0]  act_exp_e  = (activation_exp == 8'd0) ? 8'd1 : activation_exp;
    wire signed [10:0] e_p = $signed({3'd0, act_exp_e}) + $signed({3'd0, scale}) - 11'sd262;

    // scale code 255 is NaN, and infinity times a zero code is NaN
    wire is_nan = activation_nan || (scale == 8'hff) ||
                  (activation_inf && weight[2:0] == 0);
    wire is_inf = activation_inf && weight[2:0] != 0;

    wire [31:0] product;
    fp32_pack #(.MANT_W(12)) u_pack (
        .magnitude (magnitude),
        .exponent  (e_p),
        .sign      (negative),
        .is_inf    (is_inf),
        .is_nan    (is_nan),
        .result    (product)
    );

    reg  [31:0] acc;
    wire [31:0] acc_next;

    fp32_add u_add (.a(acc), .b(product), .result(acc_next));

    // One product per row: arm on prepare, consume on the first step after it.
    // The engine's remaining ACC phases still present step, and are ignored.
    reg armed;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       armed <= 1'b0;
        else if (prepare) armed <= 1'b1;
        else if (step)    armed <= 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc          <= 32'd0;
            result       <= 32'd0;
            result_valid <= 1'b0;
        end else begin
            if (clear) begin
                acc          <= 32'd0;
                result       <= 32'd0;
                result_valid <= 1'b0;
            end
            if (step && armed)
                acc <= acc_next;
            if (finish) begin
                result       <= acc;
                result_valid <= 1'b1;
            end
        end
    end

    // abs_init / abs_mode / capture exist for the exact lane's magnitude
    // extraction and product capture.  Accumulation here is already signed, so
    // they are accepted and unused.
    wire unused_abs = abs_init | abs_mode | capture | word_phase[4];
endmodule
