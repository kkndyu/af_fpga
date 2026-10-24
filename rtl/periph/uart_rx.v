`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// uart_rx - byte receiver
// -----------------------------------------------------------------------------
// Deliberately knows nothing about the protocol above it.  It turns a serial line
// into a byte stream with a standard valid/ready handshake, so the loader that
// consumes it can be pointed at an Ethernet payload instead without changing.
//
// Sampling: detect the falling edge of the start bit, wait half a bit period to
// reach the centre of the start bit, confirm it is still low (a glitch is not a
// frame), then sample every bit period.  No 16x oversampling and no majority
// vote: at CLK/BAUD = 1736 clocks per bit the sampling point can drift by
// hundreds of clocks and still land safely inside the bit, so the extra
// machinery would buy nothing.
//
// CLK_FREQ and BAUD_RATE are parameters, not constants, so a different board or a
// faster bridge chip only changes two numbers.  The baud rate is UNVERIFIED above
// 115200 - see docs/board_pinout.md; the bridge chip is unidentified.
// -----------------------------------------------------------------------------
module uart_rx #(
    parameter CLK_FREQ  = 200_000_000,
    parameter BAUD_RATE = 115200
)(
    input             clk,
    input             rst_n,

    input             rx,        // serial input, idle high

    output reg [7:0]  data,
    output reg        valid,     // held high until ready is seen
    input             ready
);

    localparam integer BIT_CLKS = CLK_FREQ / BAUD_RATE;      // 1736 at 200 MHz
    localparam integer HALF     = BIT_CLKS / 2;

    // One-bit-period timer, shared by the start/done states.
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;   // wait to the middle of the start bit
    localparam S_DATA  = 2'd2;   // sample 8 data bits
    localparam S_STOP  = 2'd3;   // sample the stop bit

    reg [1:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shreg;
    reg        rx_meta;   // first synchroniser stage
    reg        rx_d;      // second stage: this is the one the FSM looks at

    wire rx_fall = rx_d & ~rx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= S_IDLE;
            cnt     <= 16'd0;
            bit_idx <= 3'd0;
            shreg   <= 8'd0;
            rx_meta <= 1'b1;
            rx_d    <= 1'b1;
            data    <= 8'd0;
            valid   <= 1'b0;
        end else begin
            // Two-stage synchroniser.  rx is an asynchronous board input, so one
            // register is not enough: a single flop can go metastable and the FSM
            // then samples a glitched start edge.  The XDC already claimed two
            // stages; this makes the claim true.
            rx_meta <= rx;
            rx_d    <= rx_meta;

            // Handshake: hold the byte until the consumer takes it.
            if (valid && ready) valid <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (rx_fall && !valid) begin
                        cnt <= 16'd0;
                        st  <= S_START;
                    end
                end

                // Wait HALF a bit period, then confirm the start bit is real.
                S_START: begin
                    if (cnt == HALF - 1) begin
                        cnt <= 16'd0;
                        if (!rx) begin
                            bit_idx <= 3'd0;
                            st      <= S_DATA;
                        end else begin
                            st <= S_IDLE;          // glitch, not a frame
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                // Sample each data bit at its centre.  LSB first.
                S_DATA: begin
                    if (cnt == BIT_CLKS - 1) begin
                        cnt        <= 16'd0;
                        shreg[bit_idx] <= rx;
                        if (bit_idx == 3'd7) begin
                            st <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                // A framing error (stop bit low) drops the byte silently.  The
                // protocol layer has a CRC, so a damaged byte would be caught
                // there anyway; this just avoids handing out an obviously broken
                // frame.
                S_STOP: begin
                    if (cnt == BIT_CLKS - 1) begin
                        cnt <= 16'd0;
                        if (rx) begin
                            data  <= shreg;
                            valid <= 1'b1;
                        end
                        st <= S_IDLE;
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
