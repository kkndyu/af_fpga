// IEEE binary32 addition: round-to-nearest-even, gradual underflow, signed
// zeros, infinities and canonical NaN. Combinational reference datapath;
// the integrated MAC must explicitly account for its feedback latency.
module fp32_add (
    input [31:0] a,
    input [31:0] b,
    output reg [31:0] result
);
    function [26:0] shift_jam;
        input [26:0] value;
        input integer distance;
        integer n;
        reg sticky;
        reg [26:0] shifted;
        begin
            sticky = 1'b0;
            shifted = 27'd0;
            if (distance == 0) shifted = value;
            else if (distance >= 27) shifted = {26'd0, |value};
            else begin
                shifted = value >> distance;
                for (n = 0; n < 27; n = n + 1)
                    if (n < distance) sticky = sticky | value[n];
                shifted[0] = shifted[0] | sticky;
            end
            shift_jam = shifted;
        end
    endfunction
    reg [31:0] larger_operand, smaller_operand;
    reg [23:0] lm, sm;
    reg [26:0] aligned;
    reg [27:0] sum;
    reg [24:0] rounded;
    reg negative;
    integer le, se, exp, i;
    always @* begin
        larger_operand = a;
        smaller_operand = b;
        lm = 0; sm = 0; aligned = 0; sum = 0; rounded = 0;
        negative = 0; le = 0; se = 0; exp = 0;
        result = 32'd0;
        if ((a[30:23] == 255 && a[22:0] != 0) ||
            (b[30:23] == 255 && b[22:0] != 0)) result = 32'h7fc00000;
        else if (a[30:23] == 255 && b[30:23] == 255 && a[31] != b[31]) result = 32'h7fc00000;
        else if (a[30:23] == 255) result = a;
        else if (b[30:23] == 255) result = b;
        else if (a[30:0] == 0 && b[30:0] == 0) result = {a[31] & b[31], 31'd0};
        else if (a[30:0] == 0) result = b;
        else if (b[30:0] == 0) result = a;
        else begin
            if (a[30:0] < b[30:0]) begin larger_operand = b; smaller_operand = a; end
            negative = larger_operand[31];
            le = larger_operand[30:23] == 0 ? 1 : larger_operand[30:23];
            se = smaller_operand[30:23] == 0 ? 1 : smaller_operand[30:23];
            exp = le;
            lm = {(|larger_operand[30:23]), larger_operand[22:0]};
            sm = {(|smaller_operand[30:23]), smaller_operand[22:0]};
            aligned = shift_jam({sm, 3'd0}, le-se);
            if (larger_operand[31] == smaller_operand[31]) sum = {1'b0, lm, 3'd0} + {1'b0, aligned};
            else sum = {1'b0, lm, 3'd0} - {1'b0, aligned};
            if (sum != 0) begin
                if (sum[27]) begin
                    sum = {1'b0, sum[27:1]} | {27'd0, sum[0]};
                    exp = exp + 1;
                end else begin
                    for (i = 0; i < 26; i = i + 1) begin
                        if (!sum[26] && exp > 1) begin sum = sum << 1; exp = exp - 1; end
                    end
                end
                rounded = {1'b0, sum[26:3]} + (sum[2] && (sum[1] || sum[0] || sum[3]));
                if (rounded[24]) begin rounded = rounded >> 1; exp = exp + 1; end
                if (exp >= 255) result = {negative, 8'hff, 23'd0};
                else if (exp == 1 && !rounded[23]) result = {negative, 8'd0, rounded[22:0]};
                else result = {negative, exp[7:0], rounded[22:0]};
            end
        end
    end
endmodule
