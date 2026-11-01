// BF16 x E2M1 x E8M0 lane with exact, full-range accumulation.
// The 544-bit signed accumulator has LSB 2^-261. A finite product occupies
// at most bits 0..518; 1024 terms need at most bit 528, leaving sign/headroom.
// A 32-bit rotating adder processes one term in 17 steps, avoiding a 544-bit
// carry chain. Only the completed dot product is rounded to FP32 (RNE).
module mxfp4_lane (
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
    // Keep resettable rotating storage in FFs. SRL extraction expands the
    // synchronous clear into per-bit logic and exceeds this device's LUT budget.
    (* shreg_extract = "no" *) reg [543:0] accumulator;
    (* dont_touch = "true" *) reg clear_local, step_local;
    reg [4:0] phase_local;
    reg abs_local;
    reg term_negative, abs_negative, carry;
    reg [31:0] fragment_lo;
    reg [10:0] fragment_hi;
    reg [4:0] fragment_word;
    reg saw_nan, saw_pos_inf, saw_neg_inf;
    reg below_previous, below_top;
    wire [11:0] selected = magnitude_flat[weight[2:0]*12 +: 12];
    wire negative = activation_sign ^ weight[3];
    wire bad = activation_nan || (scale == 8'hff) || (activation_inf && weight[2:0] == 0);
    wire [8:0] incoming_shift = {1'b0, activation_exp == 0 ? 8'd1 : activation_exp} + {1'b0, scale} - 9'd1;
    // Reuse fragment registers: capture holds raw mantissa/shift; prepare
    // replaces them with the two aligned words. No separate operand bank.
    wire [42:0] shifted = {31'd0, fragment_lo[11:0]} << fragment_hi[4:0];
    // During magnitude extraction, the preceding word is already at the
    // rotating accumulator's high end. A separate 32-bit history FF is wasteful.
    wire [31:0] previous_word = phase_local == 0 ? 32'd0 : accumulator[543:512];
    // Decode the next rotating word in parallel with the delayed step control.
    // Registering here removes phase comparators/muxes from the carry-chain path.
    wire [31:0] next_fragment = word_phase == fragment_word ? fragment_lo :
                          word_phase == fragment_word + 5'd1 ? {21'd0, fragment_hi} : 32'd0;
    reg [31:0] term_word_q;
    always @(posedge clk) term_word_q <= next_fragment ^ {32{term_negative}};
    wire [31:0] addend = abs_local ? (accumulator[31:0] ^ {32{abs_negative}}) :
                                             term_word_q;
    wire [31:0] base_word = abs_local ? 32'd0 : accumulator[31:0];
    wire [32:0] addition = {1'b0, base_word} + {1'b0, addend} + carry;
    // In absolute mode carry is zero for a positive accumulator. For a
    // negative accumulator, ~word + carry is zero iff word is all ones
    // (carry=0) or all zeros (carry=1). Avoid adder -> reduction -> FF enable.
    wire abs_word_nonzero = abs_negative && !carry ? !(&accumulator[31:0]) :
                                                                     (|accumulator[31:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clear_local <= 1; step_local <= 0; phase_local <= 0; abs_local <= 0;
        end else begin
            clear_local <= clear; step_local <= step;
            phase_local <= word_phase; abs_local <= abs_mode;
        end
    end
    // Synchronous clear maps to the FF reset input; no 544-bit data mux.
    // Global reset invalidates control/results; RUN clears storage before use.
    always @(posedge clk) begin
        if (clear_local) accumulator <= 544'd0;
        else if (step_local) accumulator <= {addition[31:0], accumulator[543:32]};
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            term_negative <= 0;
            fragment_lo <= 0; fragment_hi <= 0; fragment_word <= 0;
            abs_negative <= 0; carry <= 0;
            saw_nan <= 0; saw_pos_inf <= 0; saw_neg_inf <= 0;
            below_previous <= 0; below_top <= 0;
        end else if (clear) begin
            saw_nan <= 0; saw_pos_inf <= 0; saw_neg_inf <= 0; carry <= 0;
            below_previous <= 0; below_top <= 0;
        end else begin
            if (capture) begin
                fragment_lo <= (bad || activation_inf) ? 32'd0 : {20'd0, selected};
                fragment_hi <= {6'd0, incoming_shift[4:0]};
                fragment_word <= {1'b0, incoming_shift[8:5]};
                term_negative <= negative;
                if (bad) saw_nan <= 1;
                if (activation_inf && !bad) begin
                    if (negative) saw_neg_inf <= 1;
                    else saw_pos_inf <= 1;
                end
            end
            if (prepare) begin
                fragment_lo <= shifted[31:0]; fragment_hi <= shifted[42:32];
                carry <= term_negative;
            end else if (abs_init) begin
                abs_negative <= accumulator[543]; carry <= accumulator[543];
                fragment_word <= 0; below_previous <= 0; below_top <= 0;
            end else if (step_local) begin
                carry <= addition[32];
                if (abs_local) begin
                    if (abs_word_nonzero) begin
                        fragment_word <= phase_local; below_top <= below_previous;
                    end
                    below_previous <= below_previous || (|previous_word);
                end
            end
        end
    end

    // Serialize final normalization as well. The 64-bit window plus sticky
    // represents the highest two magnitude words and all lower nonzero bits.
    localparam N_IDLE=0, N_LEFT=1, N_RIGHT=2, N_GUARD=3, N_ROUND=4, N_PACK=5;
    reg [2:0] normal_state;
    reg [63:0] window;
    reg sticky;
    reg round_increment;
    reg signed [10:0] exponent;
    wire increment = window[39] && ((|window[38:0]) || sticky || window[40]);
    wire [24:0] rounded = {1'b0, window[63:40]} + round_increment;
    // Once normalization is complete exponent holds the biased exponent;
    // result temporarily holds the rounded mantissa before the packing cycle.
    wire [8:0] rounded_exp = {1'b0, exponent[7:0]} + result[24];
    wire [23:0] rounded_mant = result[24] ? result[24:1] : result[23:0];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            normal_state <= N_IDLE; result <= 0; result_valid <= 0;
            window <= 0; sticky <= 0; exponent <= 0; round_increment <= 0;
        end else if (clear) begin
            normal_state <= N_IDLE; result <= 0; result_valid <= 0;
            window <= 0;
        end else begin
            if (abs_init) window <= 0;
            if (step_local && abs_local && abs_word_nonzero)
                window <= {addition[31:0], previous_word};
            if (finish) begin
                sticky <= below_top;
                exponent <= $signed({1'b0, fragment_word, 5'd0}) - 11'sd230;
                // Highest word index * 32 + 31 - 261.
                if (saw_nan || (saw_pos_inf && saw_neg_inf)) begin
                    result <= 32'h7fc00000; result_valid <= 1; normal_state <= N_IDLE;
                end else if (saw_pos_inf || saw_neg_inf) begin
                    result <= {saw_neg_inf, 8'hff, 23'd0}; result_valid <= 1; normal_state <= N_IDLE;
                end else if (window == 0) begin
                    result <= 0; result_valid <= 1; normal_state <= N_IDLE;
                end else normal_state <= N_LEFT;
            end else case (normal_state)
                N_LEFT: begin
                    if (!window[63]) begin window <= window << 1; exponent <= exponent - 11'sd1; end
                    else if (exponent > 11'sd127) begin
                        result <= {abs_negative, 8'hff, 23'd0}; result_valid <= 1; normal_state <= N_IDLE;
                    end else if (exponent < -11'sd126) normal_state <= N_RIGHT;
                    else begin exponent <= exponent + 11'sd127; normal_state <= N_GUARD; end
                end
                N_RIGHT: begin
                    if (exponent < -11'sd126) begin
                        sticky <= sticky || window[0]; window <= window >> 1;
                        exponent <= exponent + 11'sd1;
                    end else begin exponent <= 11'd1; normal_state <= N_GUARD; end
                end
                N_GUARD: begin round_increment <= increment; normal_state <= N_ROUND; end
                N_ROUND: begin
                    result <= {7'd0, rounded}; normal_state <= N_PACK;
                end
                N_PACK: begin
                    if (rounded_exp >= 255) result <= {abs_negative, 8'hff, 23'd0};
                    else if (rounded_exp == 1 && !rounded_mant[23]) result <= {abs_negative, 8'd0, rounded_mant[22:0]};
                    else result <= {abs_negative, rounded_exp[7:0], rounded_mant[22:0]};
                    result_valid <= 1; normal_state <= N_IDLE;
                end
                default: normal_state <= N_IDLE;
            endcase
        end
    end
endmodule
