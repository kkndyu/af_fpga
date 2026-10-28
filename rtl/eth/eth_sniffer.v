`include "moe_params.vh"

// -----------------------------------------------------------------------------
// eth_sniffer  -  2048-entry circular capture of the received byte stream
// -----------------------------------------------------------------------------
// Every byte the PHY hands over while RX_DV is asserted is written into a 2048 x
// 16 circular buffer, one entry per byte:
//
//     [15]     always 1, so an unused entry reads back as zero
//     [7:0]    the byte, exactly as it came off the wire
//
// 2048 bytes covers a maximum-length frame with room to spare, so after any frame
// the buffer contains the whole thing verbatim - preamble and delimiter included,
// because mac_rx is fed the raw GMII stream.
//
// Why this and not another counter
//   Every counter so far has answered "how many" when the question was "what".
//   The error counters cannot say whether the bytes are shifted by a nibble,
//   bit-reversed, all zeros, or perfectly good frames for someone else.  Looking
//   at the bytes answers all of those at once.
//
// Readback
//   raddr is set from the host, rdata returns the entry.  wr_ptr tells the host
//   where the newest byte sits, so a capture can be walked in order.
// -----------------------------------------------------------------------------
module eth_sniffer (
    input             clk,
    input             rst_n,

    // wire side
    input      [7:0]  rx_data,
    input             rx_dv,

    // host side
    input      [10:0] raddr,
    output reg [15:0] rdata,

    output reg [10:0] wr_ptr,
    output reg [15:0] byte_count
);

    localparam DEPTH = 2048;

    (* ram_style = "block" *) reg [15:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (rx_dv) mem[wr_ptr] <= {1'b1, rx_data};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr     <= 11'd0;
            byte_count <= 16'd0;
        end else if (rx_dv) begin
            wr_ptr     <= wr_ptr + 11'd1;
            // Saturates rather than wraps: it is a "has anything ever arrived"
            // indicator, and a wrapped count is worse than a clipped one.
            if (byte_count != 16'hFFFF)
                byte_count <= byte_count + 16'd1;
        end
    end

    always @(posedge clk) begin
        rdata <= mem[raddr];
    end

endmodule
