`include "moe_params.vh"
module mxfp4_gemv_engine #(
    parameter K_LEN=`H_DIM, parameter K_ADDR_W=`H_ADDR_W
)(
    input clk, rst_n, start,
    output busy,
    output reg done,
    input w_wr_en,
    input [1:0] w_wr_region,
    input [K_ADDR_W-1:0] w_wr_addr,
    input [255:0] w_wr_data,
    input act_wr_en,
    input [K_ADDR_W-1:0] act_wr_addr,
    input [15:0] act_wr_data,
    input scale_wr_en,
    input [1:0] scale_wr_region,
    input [10:0] scale_wr_addr,
    input [7:0] scale_wr_data,
    input rb_start,
    input [1:0] rb_region,
    input [K_ADDR_W-1:0] rb_addr,
    input [15:0] rb_nrows,
    input rb_byte_ready,
    output [7:0] rb_byte_out,
    output rb_byte_valid, rb_done,
    output [8191:0] acc_flat
);
    localparam IDLE=0, CLEAR=1, READ=2, DECODE=3, CAPTURE=4, PREPARE=5, ACC=6,
               DRAIN=7, ABS_INIT=8, ABS=9, ABS_DRAIN=10, FINISH=11, WAIT=12, PRODUCTS=13;
    reg [3:0] state;
    reg [K_ADDR_W-1:0] row;
    reg [4:0] phase;
    reg output_group;
    wire [1023:0] weight_rows;
    wire [3:0] ready;
    wire rb_en, rb_busy;
    wire [1:0] rb_bank;
    wire [K_ADDR_W-1:0] rb_row;
    wire read_en = state == READ;
    wire [K_ADDR_W-1:0] bank_addr = rb_en ? rb_row : row;
    wire [255:0] rb_data = weight_rows[rb_bank*256 +: 256];
    assign busy = state != IDLE;
    weight_readback #(.ROW_W(256), .ADDR_W(K_ADDR_W)) u_readback (
        .clk(clk), .rst_n(rst_n), .start(rb_start && !busy), .region(rb_region), .addr(rb_addr), .nrows(rb_nrows),
        .rb_en(rb_en), .rb_region(rb_bank), .rb_addr(rb_row), .rb_data(rb_data),
        .byte_out(rb_byte_out), .byte_valid(rb_byte_valid), .byte_ready(rb_byte_ready), .busy(rb_busy), .done(rb_done));
    genvar region;
    generate for (region=0; region<4; region=region+1) begin : gen_region
        wbank_region #(.DEPTH(K_LEN), .ADDR_W(K_ADDR_W), .DATA_W(256)) u_weights (
            .clk(clk), .wr_en(w_wr_en && w_wr_region == region), .wr_addr(w_wr_addr), .wr_data(w_wr_data),
            .rd_en(read_en || (rb_en && rb_bank == region)), .rd_addr(bank_addr), .rd_data(weight_rows[region*256 +: 256]));
        mxfp4_region #(.K_LEN(K_LEN), .K_ADDR_W(K_ADDR_W)) u_region (
            .clk(clk), .rst_n(rst_n), .act_wr_en(act_wr_en), .act_wr_addr(act_wr_addr), .act_wr_data(act_wr_data),
            .scale_wr_en(scale_wr_en && scale_wr_region == region), .scale_wr_addr(scale_wr_addr), .scale_wr_data(scale_wr_data),
            .read_en(read_en), .read_addr(row), .decode(state == DECODE), .clear(state == CLEAR),
            .output_group(output_group), .save_results(state == WAIT && (&ready)),
            .products_capture(state == PRODUCTS),
            .capture(state == CAPTURE), .prepare(state == PREPARE), .abs_init(state == ABS_INIT),
            .step(state == ACC || state == ABS), .abs_mode(state == ABS), .finish(state == FINISH), .word_phase(phase),
            .weight_row(weight_rows[region*256 +: 256]), .results(acc_flat[region*2048 +: 2048]), .ready(ready[region]));
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; row <= 0; phase <= 0; done <= 0; output_group <= 0; end
        else begin
            done <= 0;
            case (state)
                IDLE: if (start && !rb_busy) begin row <= 0; output_group <= 0; state <= CLEAR; end
                CLEAR: state <= READ;
                READ: state <= DECODE;
                DECODE: state <= PRODUCTS;
                PRODUCTS: state <= CAPTURE;
                CAPTURE: state <= PREPARE;
                PREPARE: begin phase <= 0; state <= ACC; end
`ifdef MOE_MXFP4_FP32
                // One addition per row, so two phases are enough.  The exact lane
                // needs all 17 for its rotating carry chain.
                ACC: if (phase == 1) begin
`else
                ACC: if (phase == 16) begin
`endif
                    if (row == K_LEN-1) state <= DRAIN;
                    else begin row <= row + 1'b1; state <= READ; end
                end else phase <= phase + 1'b1;
`ifdef MOE_MXFP4_FP32
                  // No final magnitude extraction: accumulation is already signed.
                  DRAIN: state <= FINISH;
`else
                  DRAIN: state <= ABS_INIT;
`endif
`ifndef MOE_MXFP4_FP32
                  ABS_INIT: begin phase <= 0; state <= ABS; end
                  ABS: if (phase == 16) state <= ABS_DRAIN; else phase <= phase + 1'b1;
                  ABS_DRAIN: state <= FINISH;
`endif
                FINISH: state <= WAIT;
                WAIT: if (&ready) begin
                    if (!output_group) begin output_group <= 1; row <= 0; state <= CLEAR; end
                    else begin state <= IDLE; done <= 1; end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule