`include "moe_params.vh"

// -----------------------------------------------------------------------------
// mac_lane
// -----------------------------------------------------------------------------
// One output lane ("通道").
//
// It matches the reference sub-array diagram:
//
//   通道权重寄存器  ->  候选乘积选择模块  ->  (缩放计算模块)  ->  累加
//   (wcode_q)          (fp4_select)          (not implemented)
//
// The weight register lives HERE, not in the region.
//
// The reference weight-distribution diagram is explicit about the chain:
//
//   WBank N -> 权重读出寄存器 523 -> 局部分发寄存器 524 (optional)
//           -> 通道 0..63 权重寄存器 -> 候选乘积选择模块
//
// so the LAST register before the mux is per-lane (4 bits each, 64 per region),
// not one 256-bit register in the middle of the region.  The bit count is the
// same either way; what differs is that a per-lane register sits next to the mux
// it drives, so the mux select has essentially no routing to do.
//
// Mapping to the reference diagram:
//   WBank N                = u_wbank_r{0..3} inside gemv_engine
//   权重读出寄存器 523      = that wbank's rd_data output register (wcode_r*)
//   局部分发寄存器 524      = wcode_d in mac_region
//   通道权重寄存器          = wcode_q here
// -----------------------------------------------------------------------------
module mac_lane #(
    parameter WCODE_W = `WCODE_W,
    parameter PROD_W  = `PROD_W,
    parameter ACC_W   = `ACC_W
)(
    input                         clk,
    input                         rst_n,
    input                         clear_acc,
    input                         acc_en,

    // Weight code coming from the region's local distribution register.
    input      [WCODE_W-1:0]      wcode,

    input      [(`FP4_CODES*PROD_W)-1:0] prod16_flat,
    output reg signed [ACC_W-1:0] acc_out
);

    // 通道权重寄存器 - one per lane, placed beside its own mux.
    (* dont_touch = "true" *) reg [WCODE_W-1:0] wcode_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wcode_q <= {WCODE_W{1'b0}};
        else        wcode_q <= wcode;
    end

    wire signed [PROD_W-1:0] selected_prod;

    // ------------------------------------------------------------------
    // Selection register - the natural home of the 缩放计算模块
    // ------------------------------------------------------------------
    // This sits exactly where the reference diagram puts 缩放计算模块 (the
    // per-lane scaling stage): between 候选乘积选择模块 and the accumulator.
    // That stage is not implemented yet - I do not know its arithmetic - but the
    // pipeline register belongs there regardless.
    //
    // Measured why: with everything else fixed, the critical path at a 200 MHz
    // constraint was the whole select-plus-add in one cycle:
    //
    //   u_region0/prod16_q_reg[169]  ->  u_region0/gen_lane[0]/acc_out_reg[29]
    //   4.114 ns, 11 levels (CARRY4 x8)
    //
    // Splitting it here leaves the 16:1 mux on one side and the 32-bit adder on
    // the other, each with roughly half the depth.  Costs one cycle of pipeline
    // latency and 24 flip-flops per lane (6144 total, ~2.3 % of the device).
    (* dont_touch = "true" *) reg signed [PROD_W-1:0] sel_prod_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sel_prod_q <= {PROD_W{1'b0}};
        else        sel_prod_q <= selected_prod;
    end

    wire signed [ACC_W-1:0]  selected_ext;

    fp4_select #(
        .PROD_W(PROD_W),
        .WCODE_W(WCODE_W)
    ) u_fp4_select (
        .wcode(wcode_q),
        .prod16_flat(prod16_flat),
        .selected_prod(selected_prod)
    );

    assign selected_ext = {{(ACC_W-PROD_W){sel_prod_q[PROD_W-1]}}, sel_prod_q};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= {ACC_W{1'b0}};
        end else if (clear_acc) begin
            acc_out <= {ACC_W{1'b0}};
        end else if (acc_en) begin
            acc_out <= acc_out + selected_ext;
        end
    end

endmodule
