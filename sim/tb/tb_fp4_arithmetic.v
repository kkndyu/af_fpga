`timescale 1ns/1ps
module tb_fp4_arithmetic;
    reg [15:0] activation;
    reg [3:0] weight;
    wire [31:0] product;
    reg [31:0] a, b, magnitude;
    reg signed [10:0] exponent;
    reg sign, is_inf, is_nan;
    wire [31:0] sum, packed;
    reg [31:0] expected;
    integer fd, rc, count, errors, exponent_int, sign_int, inf_int, nan_int;
    fp4_bf16_mul u_mul(.activation(activation), .weight(weight), .result(product));
    fp32_add u_add(.a(a), .b(b), .result(sum));
    fp32_pack #(.MANT_W(32)) u_pack(.magnitude(magnitude), .exponent(exponent),
        .sign(sign), .is_inf(is_inf), .is_nan(is_nan), .result(packed));
    initial begin
        activation = 0; weight = 0; a = 0; b = 0; magnitude = 0;
        exponent = 0; sign = 0; is_inf = 0; is_nan = 0; errors = 0;
        fd = $fopen("build/fp4_arithmetic/mul.txt", "r");
        if (!fd) $fatal(1, "Missing arithmetic vectors; run node scripts/gen_fp4_arithmetic_vectors.js");
        count = 0;
        while (!$feof(fd)) begin
            rc = $fscanf(fd, "%h %h %h\n", activation, weight, expected);
            if (rc == 3) begin
                #1;
                if (product !== expected) begin
                    if (errors < 10) $display("MUL FAIL a=%h w=%h got=%h expected=%h", activation, weight, product, expected);
                    errors = errors + 1;
                end
                count = count + 1;
            end else if (!$feof(fd)) $fatal(1, "Malformed multiplication vector");
        end
        $fclose(fd);
        if (count != 1048576) $fatal(1, "Incomplete exhaustive BF16/E2M1 corpus");
        $display("FP4 ARITH: checked %0d exhaustive BF16 x E2M1 products", count);
        fd = $fopen("build/fp4_arithmetic/add.txt", "r");
        if (!fd) $fatal(1, "Missing addition vectors");
        count = 0;
        while (!$feof(fd)) begin
            rc = $fscanf(fd, "%h %h %h\n", a, b, expected);
            if (rc == 3) begin
                #1;
                if (sum !== expected) begin
                    if (errors < 10) $display("ADD FAIL a=%h b=%h got=%h expected=%h", a, b, sum, expected);
                    errors = errors + 1;
                end
                count = count + 1;
            end else if (!$feof(fd)) $fatal(1, "Malformed addition vector");
        end
        $fclose(fd);
        if (count < 200000) $fatal(1, "Incomplete addition corpus");
        $display("FP4 ARITH: checked %0d FP32 additions", count);
        fd = $fopen("build/fp4_arithmetic/pack.txt", "r");
        if (!fd) $fatal(1, "Missing packing vectors");
        count = 0;
        while (!$feof(fd)) begin
            rc = $fscanf(fd, "%h %d %d %d %d %h\n", magnitude, exponent_int, sign_int, inf_int, nan_int, expected);
            if (rc == 6) begin
                exponent = exponent_int; sign = sign_int; is_inf = inf_int; is_nan = nan_int;
                #1;
                if (packed !== expected) begin
                    if (errors < 10) $display("PACK FAIL m=%h exp=%0d sign=%0d got=%h expected=%h", magnitude, exponent_int, sign_int, packed, expected);
                    errors = errors + 1;
                end
                count = count + 1;
            end else if (!$feof(fd)) $fatal(1, "Malformed packing vector");
        end
        $fclose(fd);
        if (count < 100000) $fatal(1, "Incomplete packing corpus");
        $display("FP4 ARITH: checked %0d significand/exponent conversions", count);
        if (errors) $fatal(1, "FP4 arithmetic: %0d mismatches", errors);
        $display("FP4 ARITHMETIC: ALL TESTS PASSED");
        $finish;
    end
endmodule
