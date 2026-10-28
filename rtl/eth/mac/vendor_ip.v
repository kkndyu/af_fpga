`include "moe_params.vh"

// -----------------------------------------------------------------------------
// Vendor IP replacements
// -----------------------------------------------------------------------------
// The vendor's MAC (rtl/eth/mac/) is a working, board-proven design, and the
// decision was taken to use it rather than keep debugging a hand-written stack.
// It depends on four generated Xilinx cores, which do not exist in this project:
//
//   udp_rx_ram_8_2048     dual-port RAM, 2048 x 8   (udp_rx.v)
//   icmp_rx_ram_8_256     dual-port RAM,  256 x 8   (icmp_reply.v)
//   udp_tx_data_fifo      synchronous FIFO,  8 bit  (udp_tx.v)
//   udp_checksum_fifo     synchronous FIFO, 32 bit  (udp_tx.v)
//
// Each is reproduced here with the same module name and the same port names, so
// the vendor RTL is used verbatim and unmodified.  Re-generating the IP would work
// too, but an equivalent in plain RTL keeps the build reproducible from source
// and removes four .xci files from the tree.
//
// Read semantics matter and are chosen to match what a block-memory generator
// produces by default:
//
//   RAMs   : write on clka, READ IS REGISTERED on clkb (one cycle of latency)
//   FIFOs  : dout is registered, not first-word-fall-through, so dout holds the
//            word after rd_en has been seen for one clock
//
// The FIFO latency is the one assumption worth re-checking if the vendor's
// transmitter misbehaves: a first-word-fall-through FIFO would show valid data
// one cycle earlier.
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Dual-port RAM, registered read on port B
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// 2048 x 8, exactly the ports udp_rx.v expects
// -----------------------------------------------------------------------------
module udp_rx_ram_8_2048 (
    input             clka,
    input      [0:0]  wea,
    input      [10:0] addra,
    input      [7:0]  dina,
    input             clkb,
    input      [10:0] addrb,
    output reg [7:0]  doutb
);
    reg [7:0] mem [0:2047];

    always @(posedge clka) begin
        if (wea[0]) mem[addra] <= dina;
    end

    always @(posedge clkb) begin
        doutb <= mem[addrb];
    end
endmodule

// -----------------------------------------------------------------------------
// 256 x 8, exactly the ports icmp_reply.v expects
// -----------------------------------------------------------------------------
module icmp_rx_ram_8_256 (
    input             clka,
    input      [0:0]  wea,
    input      [7:0]  addra,
    input      [7:0]  dina,
    input             clkb,
    input      [7:0]  addrb,
    output reg [7:0]  doutb
);
    reg [7:0] mem [0:255];

    always @(posedge clka) begin
        if (wea[0]) mem[addra] <= dina;
    end

    always @(posedge clkb) begin
        doutb <= mem[addrb];
    end
endmodule

// -----------------------------------------------------------------------------
// 8-bit synchronous FIFO, 2048 deep, registered output
// -----------------------------------------------------------------------------
module udp_tx_data_fifo (
    input             clk,
    input             srst,
    input      [7:0]  din,
    input             wr_en,
    input             rd_en,
    output reg [7:0]  dout,
    output            full,
    output            almost_full,
    output            empty,
    output     [11:0] data_count
);
    localparam AW    = 11;                 // 2048 entries
    localparam DEPTH = (1 << AW);

    reg [7:0]     mem [0:DEPTH-1];
    reg [AW:0]    wp, rp;

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always @(posedge clk) begin
        if (srst) begin
            wp   <= {(AW+1){1'b0}};
            rp   <= {(AW+1){1'b0}};
            dout <= 8'd0;
        end else begin
            if (do_wr) mem[wp[AW-1:0]] <= din;
            if (do_wr) wp <= wp + 1'b1;
            if (do_rd) begin
                rp   <= rp + 1'b1;
                dout <= mem[rp[AW-1:0]];
            end
        end
    end

    assign empty       = (wp == rp);
    assign full        = ((wp + 1'b1) == rp) || (srst && (wp == rp));
    assign almost_full = ((wp - rp) >= (DEPTH - 16));
    assign data_count  = wp - rp;
endmodule

// -----------------------------------------------------------------------------
// 32-bit synchronous FIFO, 16 deep, registered output
// -----------------------------------------------------------------------------
module udp_checksum_fifo (
    input             clk,
    input             srst,
    input      [31:0] din,
    input             wr_en,
    input             rd_en,
    output reg [31:0] dout,
    output            full,
    output            empty,
    output     [3:0]  data_count
);
    localparam AW    = 4;                  // 16 entries
    localparam DEPTH = (1 << AW);

    reg [31:0]    mem [0:DEPTH-1];
    reg [AW:0]    wp, rp;

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always @(posedge clk) begin
        if (srst) begin
            wp   <= {(AW+1){1'b0}};
            rp   <= {(AW+1){1'b0}};
            dout <= 32'd0;
        end else begin
            if (do_wr) mem[wp[AW-1:0]] <= din;
            if (do_wr) wp <= wp + 1'b1;
            if (do_rd) begin
                rp   <= rp + 1'b1;
                dout <= mem[rp[AW-1:0]];
            end
        end
    end

    assign empty      = (wp == rp);
    assign full       = ((wp + 1'b1) == rp);
    assign data_count = wp - rp;
endmodule