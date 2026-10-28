`include "moe_params.vh"

// -----------------------------------------------------------------------------
// eth_async_fifo
// -----------------------------------------------------------------------------
// Dual-clock FIFO, used twice in the gigabit path: once to carry received bytes
// from the PHY's 125 MHz RX_CLK domain into the 200 MHz fabric, and once to carry
// bytes to be transmitted the other way.
//
// Gray-coded pointers with two-flop synchronisers.  A plain handshake was not used
// because the receive side must keep up with a continuous stream - the GMII
// interface has no backpressure at all.
//
// DATA_W is 9: {flag, byte}, where the flag is start-of-frame on the receive side
// and end-of-frame on the transmit side.
// -----------------------------------------------------------------------------
module eth_async_fifo #(
    parameter DATA_W = 9,
    parameter AW     = 6                  // depth = 2**AW
)(
    input                   wclk,
    input                   wrst_n,
    input                   wen,
    input      [DATA_W-1:0] wdata,
    output                  wfull,

    input                   rclk,
    input                   rrst_n,
    input                   ren,
    output     [DATA_W-1:0] rdata,
    output                  rempty
);

    localparam integer DEPTH = (1 << AW);

    reg [DATA_W-1:0] mem [0:DEPTH-1];

    reg [AW:0] wbin, wgray;
    reg [AW:0] rbin, rgray;

    // ---- write side ----
    wire [AW:0] wbin_next  = wbin + (wen && !wfull);
    wire [AW:0] wgray_next = (wbin_next >> 1) ^ wbin_next;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= {(AW+1){1'b0}};
            wgray <= {(AW+1){1'b0}};
        end else begin
            wbin  <= wbin_next;
            wgray <= wgray_next;
        end
    end

    always @(posedge wclk) begin
        if (wen && !wfull) mem[wbin[AW-1:0]] <= wdata;
    end

    // ---- read side ----
    wire [AW:0] rbin_next  = rbin + (ren && !rempty);
    wire [AW:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin  <= {(AW+1){1'b0}};
            rgray <= {(AW+1){1'b0}};
        end else begin
            rbin  <= rbin_next;
            rgray <= rgray_next;
        end
    end

    assign rdata = mem[rbin[AW-1:0]];

    // ---- pointer synchronisers ----
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wgray_s1, wgray_s2;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rgray_s1, rgray_s2;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            wgray_s1 <= {(AW+1){1'b0}};
            wgray_s2 <= {(AW+1){1'b0}};
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            rgray_s1 <= {(AW+1){1'b0}};
            rgray_s2 <= {(AW+1){1'b0}};
        end else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    // ---- flags ----
    // Full when the write pointer one step ahead collides with the synchronised
    // read pointer with the top two bits inverted.  The +1 is taken from wbin
    // directly, not from wbin_next, because wbin_next is gated by wfull and
    // feeding it back here would close a combinational loop.
    wire [AW:0] wbin_inc  = wbin + 1'b1;
    wire [AW:0] wgray_inc = (wbin_inc >> 1) ^ wbin_inc;

    assign wfull  = (wgray_inc == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});
    assign rempty = (rgray == wgray_s2);

endmodule
