`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// uart_tx - byte transmitter
// -----------------------------------------------------------------------------
// The mirror of uart_rx: a byte stream with a valid/ready handshake becomes a
// serial line.  ready is high whenever the shifter is idle, so a producer with a
// FIFO behind it can simply push when ready.
//
// 8N1, LSB first, idle high.  The stop bit is driven for a full bit period before
// the line returns to idle, which is what the receiver's centre-sampling expects.
// -----------------------------------------------------------------------------
module uart_tx #(
    parameter CLK_FREQ  = 200_000_000,
    parameter BAUD_RATE = 115200
)(
    input             clk,
    input             rst_n,

    input      [7:0]  data,
    input             valid,
    output            ready,

    output reg        tx         // serial output, idle high
);

    localparam integer BIT_CLKS = CLK_FREQ / BAUD_RATE;

    localparam S_IDLE  = 1'd0;
    localparam S_SHIFT = 1'd1;

    reg        st;
    reg [15:0] cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shreg;

    // Accept a byte only when idle.  Asserted combinationally so the producer
    // does not need to wait a cycle before pushing.
    assign ready = (st == S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= S_IDLE;
            cnt     <= 16'd0;
            bit_idx <= 3'd0;
            shreg   <= 8'd0;
            tx      <= 1'b1;
        end else begin
            case (st)
                S_IDLE: begin
                    tx <= 1'b1;
                    if (valid) begin
                        shreg   <= data;
                        bit_idx <= 3'd0;
                        cnt     <= 16'd0;
                        tx      <= 1'b0;       // start bit
                        st      <= S_SHIFT;
                    end
                end

                // 1 start + 8 data + 1 stop = 10 bit periods.  Data bits are
                // driven from bit 1 onwards, so the start bit gets a full period.
                S_SHIFT: begin
                    if (cnt == BIT_CLKS - 1) begin
                        cnt <= 16'd0;
                        if (bit_idx == 3'd0) begin
                            tx      <= shreg[0];
                            bit_idx <= 3'd1;
                        end else if (bit_idx <= 3'd7) begin
                            tx      <= shreg[bit_idx[2:0]];
                            bit_idx <= bit_idx + 3'd1;
                        end else begin
                            tx <= 1'b1;        // stop bit
                            st <= S_IDLE;
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                default: begin
                    st <= S_IDLE;
                    tx <= 1'b1;
                end
            endcase
        end
    end

endmodule
