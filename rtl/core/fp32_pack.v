// Convert an exact unsigned significand * 2**exponent to IEEE binary32.
// Round to nearest, ties to even; gradual underflow; canonical quiet NaN.
// This combinational arithmetic primitive does not claim a one-cycle 200 MHz
// implementation. Pipeline boundaries belong in the consuming datapath.
module fp32_pack #(
    parameter MANT_W = 16
)(
    input [MANT_W-1:0] magnitude,
    input signed [10:0] exponent,
    input sign,
    input is_inf,
    input is_nan,
    output reg [31:0] result
);
    function [63:0] round_right;
        input [63:0] value;
        input integer distance;
        reg [63:0] truncated;
        reg guard_bit, sticky;
        integer n;
        begin
            truncated = 64'd0;
            guard_bit = 1'b0;
            sticky = 1'b0;
            if (distance <= 0) truncated = value;
            else if (distance <= 64) begin
                truncated = value >> distance;
                guard_bit = value[distance-1];
                for (n = 0; n < 64; n = n + 1)
                    if (n < distance-1) sticky = sticky | value[n];
                if (guard_bit && (sticky || truncated[0])) truncated = truncated + 64'd1;
            end
            round_right = truncated;
        end
    endfunction
    integer i, top, unbiased, shift, biased;
    reg [63:0] wide, rounded;
    always @* begin
        wide = {{(64-MANT_W){1'b0}}, magnitude};
        rounded = 64'd0;
        top = -1;
        unbiased = 0;
        shift = 0;
        biased = 0;
        result = {sign, 31'd0};
        for (i = 0; i < MANT_W; i = i + 1)
            if (magnitude[i]) top = i;
        if (is_nan) result = 32'h7fc00000;
        else if (is_inf) result = {sign, 8'hff, 23'd0};
        else if (top >= 0) begin
            unbiased = $signed(exponent) + top;
            if (unbiased > 127) result = {sign, 8'hff, 23'd0};
            else if (unbiased >= -126) begin
                if (top > 23) rounded = round_right(wide, top-23);
                else rounded = wide << (23-top);
                if (rounded[24]) begin
                    rounded = rounded >> 1;
                    unbiased = unbiased + 1;
                end
                biased = unbiased + 127;
                if (biased >= 255) result = {sign, 8'hff, 23'd0};
                else result = {sign, biased[7:0], rounded[22:0]};
            end else begin
                shift = $signed(exponent) + 149;
                if (shift >= 0) rounded = wide << shift;
                else rounded = round_right(wide, -shift);
                // Rounding the largest subnormal can produce the minimum normal.
                if (rounded[23]) result = {sign, 8'd1, 23'd0};
                else result = {sign, 8'd0, rounded[22:0]};
            end
        end
    end
endmodule
