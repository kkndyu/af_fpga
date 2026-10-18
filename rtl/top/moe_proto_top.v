`include "moe_params.vh"

// -----------------------------------------------------------------------------
// moe_proto_top
// -----------------------------------------------------------------------------
// Minimal top-level wrapper for the pure Verilog prototype.
//
// The GEMV result is NO LONGER exposed as an 8192-bit flat port.  A bus that
// wide becomes 8192 output pads at the top level, which cannot be placed on any
// part of this size.  Instead the result is read out through a narrow interface
// by result_readout, which indexes the accumulators directly.
//
// The 256 x 32 bit accumulator structure inside the engine is unchanged.
//
//   start        pulse to launch one GEMV
//   busy / done  engine status
//   rd_start     pulse to begin streaming the result out
//   rd_pause     hold the stream; lets a slow consumer throttle it with no FIFO
//   rd_valid     high while a result byte is on rd_data
//   rd_lane      0..255, which accumulator lane the byte belongs to
//   rd_byte      0..3, byte position within the 32-bit lane value
//   rd_data      the byte itself
// -----------------------------------------------------------------------------
module moe_proto_top (
    input                       clk,
    input                       rst_n,
    input                       start,
    output                      busy,
    output                      done,

    input                       act_wr_en,
    input      [`H_ADDR_W-1:0]  act_wr_addr,
    input      [`ACT_W-1:0]     act_wr_data,

    // Result readout, one byte at a time.
    input                       rd_start,
    input                       rd_pause,     // slow consumer throttle
    output                      rd_valid,
    output     [`E_ADDR_W-1:0]  rd_lane,
    output     [1:0]            rd_byte,
    output     [7:0]            rd_data,
    output                      rd_busy,

    // Checksum accumulated over the readout byte stream.  This is what makes
    // the result observable: without a consumer, the engine is unobservable
    // and the optimiser removes it entirely, leaving an empty shell.
    output reg [31:0]           result_checksum
);

    wire [`OUT_ACC_W-1:0] acc_flat;

    expert_engine u_expert_engine (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .busy           (busy),
        .done           (done),
        .act_wr_en      (act_wr_en),
        .act_wr_addr    (act_wr_addr),
        .act_wr_data    (act_wr_data),
        .expert_out_flat(acc_flat)
    );

    // The accumulators hold their value between GEMVs, so the readout indexes
    // acc_flat directly - there is no snapshot buffer to trigger.  As long as a
    // new GEMV is not started while a readout is in progress (this board runs
    // exactly one per reset) the data is stable.
    result_readout u_result_readout (
        .clk       (clk),
        .rst_n     (rst_n),
        .acc_flat  (acc_flat),
        .rd_start  (rd_start),
        .rd_pause  (rd_pause),
        .rd_valid  (rd_valid),
        .rd_lane   (rd_lane),
        .rd_byte   (rd_byte),
        .rd_data   (rd_data),
        .rd_busy   (rd_busy)
    );

    // ------------------------------------------------------------------
    // Checksum consumer for the readout stream
    // ------------------------------------------------------------------
    // Accumulates the 32-bit lane words as they stream out.  Only byte 3 ends
    // a lane, at which point the four bytes collected so far form the complete
    // word.  The check is order independent (a sum), so it validates the whole
    // result without needing a golden vector on chip.
    reg [31:0] lane_word;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lane_word       <= 32'd0;
            result_checksum <= 32'd0;
        end else if (rd_valid) begin
            case (rd_byte)
                2'd0: lane_word[7:0]   <= rd_data;
                2'd1: lane_word[15:8]  <= rd_data;
                2'd2: lane_word[23:16] <= rd_data;
                default: begin
                    lane_word[31:24] <= rd_data;
                    result_checksum  <= result_checksum
                                        + {rd_data, lane_word[23:16],
                                           lane_word[15:8], lane_word[7:0]};
                end
            endcase
        end
    end

endmodule
