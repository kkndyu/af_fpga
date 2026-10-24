`include "moe_params.vh"

// -----------------------------------------------------------------------------
// mac_region
// -----------------------------------------------------------------------------
// A self-contained 64-lane region: product generation, pipeline registers and 64
// accumulators, all inside one boundary.
//
// keep_hierarchy is load-bearing, not decoration
// ---------------------------------------------
// Every region holds the SAME values in its pipeline registers: the product
// vector and the weight code are functions of the shared memory read, so the
// four regions' registers are bit-identical.  Left alone, the synthesiser
// merges them into one shared pool and then re-replicates by fanout need, with
// no regard for which region a replica serves.
//
// Measured consequence at a 200 MHz constraint - 24 of the 25 worst paths had
// exactly this shape:
//
//   u_region0/prod16_q_reg[148]_rep__2  ->  u_region3/gen_lane[49]/acc_out
//   4.982 ns, slack 0.000 ns
//
// Every destination was in region 1 or region 3 (18 and 6 paths); none in
// region 0 or 2.  So region 0 and 2's registers were being used to drive
// regions 1 and 3 across the die, while each region's own feed was fine.
//
// keep_hierarchy stops the module being flattened into its parent, which stops
// cross-region pooling.  The intent could not be clearer: this boundary IS the
// physical locality boundary ("matches the later ASIC 64-lane region" in the
// original SystemVerilog), so optimisation across it is the thing to forbid.
//
// Cost: the four copies are kept in full (see dont_touch below) instead of
// being merged, roughly +2k flip-flops, about 0.8 % of the device.
// -----------------------------------------------------------------------------
// keep_hierarchy stays ON.
//
// It was briefly removed as an experiment (route_design had become erratic, and a
// structural placement constraint was the obvious suspect).  Measured result:
// routing got 24 % SLOWER and setup timing went from +0.155 ns to -0.156 ns,
// because the dont_touch registers below were then free to be scattered across
// the die - exactly the failure this attribute was added to prevent.  So it is
// load-bearing in both directions, and the routing-time variance has some other
// cause.  See docs/postmortem_routability.md.
// -----------------------------------------------------------------------------
(* keep_hierarchy = "yes" *)
module mac_region #(
    parameter REGION_LANES = `REGION_LANES,
    parameter WCODE_W      = `WCODE_W,
    parameter ACT_W        = `ACT_W,
    parameter PROD_W       = `PROD_W,
    parameter ACC_W        = `ACC_W,
    parameter K_LEN        = `H_DIM,
    parameter K_ADDR_W     = `H_ADDR_W
)(
    input                                    clk,
    input                                    rst_n,
    input                                    clear_acc,
    input                                    acc_en,

    // Activation load port.  The same write strobe is broadcast to all four
    // regions, but each region stores its own copy, so the buffer sits beside
    // the product generator that reads it.
    input                                    act_wr_en,
    input      [K_ADDR_W-1:0]                act_wr_addr,
    input      [`ACT_W-1:0]                  act_wr_data,

    // Read port for this region's own activation buffer.
    input                                    act_rd_en,
    input      [K_ADDR_W-1:0]                act_rd_addr,

    input      [(REGION_LANES*WCODE_W)-1:0]  wcode_row,
    output     [(REGION_LANES*ACC_W)-1:0]    acc_vec_flat
);

    // ------------------------------------------------------------------
    // Per-region activation buffer
    // ------------------------------------------------------------------
    // The activation vector is identical in all four regions, exactly like the
    // product generator (517) and the weight distribution that follow it, and
    // the diagram just draws one region.
    //
    // Measured why this cannot stay shared: with a single act_buffer in the
    // engine, its BRAM output had to reach all four regions' activation
    // registers, and that net became the critical path at a 200 MHz constraint:
    //
    //   u_act_buffer/mem_reg  ->  u_region0/act_q_q_reg[12]/D
    //   4.776 ns, logic levels 0, route 2.651 ns (55 %)
    //
    // Zero logic levels means it is pure routing - one BRAM output dragged
    // across the die.  Replicating the buffer makes that a short local hop.
    //
    // Cost: 1024 x 16 bit per region, four RAMB18E1 instead of one, which is
    // 8 KB of the 365-block budget.
    wire signed [ACT_W-1:0] act_q;

    act_buffer #(
        .DEPTH  (K_LEN),
        .ADDR_W (K_ADDR_W),
        .DATA_W (`ACT_W)
    ) u_act_buffer (
        .clk     (clk),
        .wr_en   (act_wr_en),
        .wr_addr (act_wr_addr),
        .wr_data (act_wr_data),
        .rd_en   (act_rd_en),
        .rd_addr (act_rd_addr),
        .rd_data (act_q)
    );

    // Combinational candidates for this activation value.
    wire [`PROD16_W-1:0] prod16_comb;

    // Activation register, first pipeline stage inside the region.
    //
    // Measured why this exists: with prod16_q and wcode_q in place the critical
    // path became
    //
    //   u_act_buffer/mem_reg  ->  <region>/prod16_q_reg[285]
    //   5.398 ns, 8 logic levels
    //
    // i.e. a BRAM access (2.1 ns clock-to-out) plus the whole product generator
    // had to fit in one clock.  Registering the activation splits that into
    // "BRAM -> act_q_q" and "act_q_q -> products -> prod16_q".
    //
    // Each region keeps its OWN copy (16 bits x 4 = 64 flip-flops total), so the
    // activation bus only has to reach four register banks rather than the
    // product generators of all four regions.
    reg  signed [ACT_W-1:0] act_q_q;

    // dont_touch on the accumulate-stage inputs.
    //
    // keep_hierarchy alone should stop cross-region pooling, but a failed
    // rebuild costs 35 minutes, so these are pinned as well.  Both are
    // bit-identical across the four regions, which is exactly the condition that
    // lets the tool merge them; pinning makes that impossible.
    //
    // prod16_q feeds the 16:1 mux data inputs of this region's lanes.
    // wcode_d  feeds the per-lane weight-code register (see mac_lane.v).
    (* dont_touch = "true" *) reg  [`PROD16_W-1:0] prod16_q;

    (* dont_touch = "true" *) reg  [`REGION_WCODE_W-1:0] wcode_d;

    // Pipeline alignment, per stage:
    //
    //   stage 1: act_q_q <= act_q        and  wcode_d <= wcode_row
    //   stage 2: prod16_q <= f(act_q_q)  and  lane.wcode_q <= wcode_d
    //
    // The products take two stages while the weight code would only take one, so
    // the mux would otherwise select with tap k+1's code while the product bus
    // held tap k - wrong, yet every individual register still looks plausible.
    // wcode_d is what restores the balance.

    fp4_product_gen #(
        .ACT_W (ACT_W),
        .PROD_W (PROD_W)
    ) u_prod_gen (
        .a           (act_q_q),
        .prod16_flat (prod16_comb)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_q_q  <= {ACT_W{1'b0}};
            prod16_q <= {`PROD16_W{1'b0}};
            wcode_d  <= {`REGION_WCODE_W{1'b0}};
        end else begin
            // Stage 1 - both sources come from synchronous memories driven by
            // the same address, so they arrive together and are registered
            // together.
            act_q_q  <= act_q;
            wcode_d  <= wcode_row;

            // Stage 2 - the product needs the whole generator, so it lands one
            // cycle after its input.  The weight code reaches the same stage
            // through the per-lane register inside mac_lane.
            prod16_q <= prod16_comb;
        end
    end

    // ------------------------------------------------------------------
    // Local accumulator enable
    // ------------------------------------------------------------------
    // acc_en from the engine is a single bit that has to reach the clock-enable
    // pin of every accumulator: 256 lanes x 32 bits = 8192 CE loads, spread over
    // four regions.  At a 200 MHz constraint that control net became the
    // critical path, and it was pure routing, not logic:
    //
    //   u_gate_gemv/c_reg[6]  ->  <lane>/acc_out_reg[24]/CE
    //   5.005 ns, logic 0.840 ns (3 levels), route 4.165 ns (83 %)
    //
    // Registering it here gives the tool one flop per region to replicate and
    // place beside its own 2048 CE pins, instead of one driver trying to reach
    // the whole die.  Same fix as the data path: replicate the signal where it
    // is consumed.
    //
    // This adds one cycle of latency, so the engine's PIPE_DEPTH accounts for it.
    reg acc_en_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) acc_en_q <= 1'b0;
        else        acc_en_q <= acc_en;
    end

    genvar i;
    generate
        for (i = 0; i < REGION_LANES; i = i + 1) begin : gen_lane
            mac_lane #(
                .WCODE_W(WCODE_W),
                .PROD_W(PROD_W),
                .ACC_W(ACC_W)
            ) u_lane (
                .clk(clk),
                .rst_n(rst_n),
                .clear_acc(clear_acc),
                .acc_en(acc_en_q),
                .wcode(wcode_d[i*WCODE_W +: WCODE_W]),
                .prod16_flat(prod16_q),
                .acc_out(acc_vec_flat[i*ACC_W +: ACC_W])
            );
        end
    endgenerate

endmodule
