`include "moe_params.vh"
(* keep_hierarchy = "yes" *)
module mxfp4_region #(
    parameter K_LEN=`H_DIM, parameter K_ADDR_W=`H_ADDR_W
)(
    input clk, rst_n,
    input act_wr_en,
    input [K_ADDR_W-1:0] act_wr_addr,
    input [15:0] act_wr_data,
    input scale_wr_en,
    input [10:0] scale_wr_addr,
    input [7:0] scale_wr_data,
    input read_en, decode, clear, capture, prepare, abs_init, step, abs_mode, finish,
    input output_group, save_results, products_capture,
    input [K_ADDR_W-1:0] read_addr,
    input [4:0] word_phase,
    input [255:0] weight_row,
    output reg [2047:0] results,
    output ready
);
    wire [15:0] activation;
    reg [15:0] activation_q;
    reg [255:0] weight_q;
    wire [95:0] magnitudes;
    reg [95:0] magnitudes_q;
    reg [7:0] activation_exp_q;
    reg sign_q, inf_q, nan_q;
    wire act_sign, act_inf, act_nan;
    always @(posedge clk) if (products_capture) begin
        magnitudes_q <= magnitudes;
        activation_exp_q <= activation_q[14:7];
        sign_q <= act_sign; inf_q <= act_inf; nan_q <= act_nan;
    end
    wire signed [10:0] unused_exp;
    // Reuse 32 physical lanes for the region's 64 logical output channels.
    // Weight/scale layout and output ordering remain unchanged.
    wire [31:0] valid;
    wire [1023:0] computed;
    wire [4:0] scale_block = read_addr >> 5;
    always @(posedge clk) if (save_results) begin
        if (output_group) results[2047:1024] <= computed;
        else results[1023:0] <= computed;
    end
    act_buffer #(.DEPTH(K_LEN), .ADDR_W(K_ADDR_W), .DATA_W(16)) u_act (
        .clk(clk), .wr_en(act_wr_en), .wr_addr(act_wr_addr), .wr_data(act_wr_data),
        .rd_en(read_en), .rd_addr(read_addr), .rd_data(activation)
    );
    always @(posedge clk) if (decode) begin activation_q <= activation; weight_q <= weight_row; end
    fp4_bf16_product_gen u_products (.activation(activation_q), .magnitude_flat(magnitudes),
        .product_exp(unused_exp), .activation_sign(act_sign), .activation_inf(act_inf), .activation_nan(act_nan));
    genvar lane;
    generate for (lane=0; lane<32; lane=lane+1) begin : gen_lane
        (* ram_style="distributed" *) reg [7:0] scales [0:63];
        reg [7:0] scale_read, scale_q;
        always @(posedge clk) begin
            if (scale_wr_en && scale_wr_addr[4:0] == lane)
                scales[{scale_wr_addr[10:6], scale_wr_addr[5]}] <= scale_wr_data;
            if (read_en) scale_read <= scales[{scale_block, output_group}];
            if (decode) scale_q <= scale_read;
        end
        // MOE_MXFP4_FP32 swaps only the accumulator representation; the port list and
        // the prepare/step/finish handshake are identical, so the name is the only
        // thing that differs.
        `ifdef MOE_MXFP4_FP32
        mxfp4_lane_fp32
        `else
        mxfp4_lane
        `endif
        u_lane (.clk(clk), .rst_n(rst_n), .clear(clear), .capture(capture),
            .prepare(prepare), .abs_init(abs_init), .step(step), .abs_mode(abs_mode), .finish(finish),
            .word_phase(word_phase), .magnitude_flat(magnitudes_q), .activation_exp(activation_exp_q),
            .activation_sign(sign_q), .activation_inf(inf_q), .activation_nan(nan_q),
            .weight(output_group ? weight_q[(lane+32)*4 +: 4] : weight_q[lane*4 +: 4]),
            .scale(scale_q), .result(computed[lane*32 +: 32]), .result_valid(valid[lane]));
    end endgenerate
    assign ready = &valid;
endmodule
