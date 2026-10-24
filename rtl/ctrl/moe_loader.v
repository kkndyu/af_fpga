`timescale 1ns/1ps
`include "moe_params.vh"

// -----------------------------------------------------------------------------
// moe_loader - transport-agnostic command loader
// -----------------------------------------------------------------------------
// Turns a byte stream carrying framed commands into memory writes and engine
// control.  It knows NOTHING about UART, Ethernet, JTAG or PCIe.
//
// The ports are named AXI4-Stream (tdata/tvalid/tready/tlast) even though the
// width is fixed at 8 bits.  That is deliberate:
//
//   * today : uart_rx drives s_axis_*, uart_tx drains m_axis_*
//   * later : a UDP payload, an AXI DMA or a PCIe XDMA stream drives the SAME
//             port through a standard AXI-Stream width converter
//
// The width stays 8 rather than being parameterised because the protocol header
// is byte-oriented (magic, command, length, CRC).  Widening means accepting
// N-byte beats and unpacking them, which is exactly what an AXI-Stream gearbox
// does; that gearbox belongs OUTSIDE this module so the parser stays one byte
// per beat and stays readable.
//
// tlast is accepted and ignored: the protocol is self-delimiting (length + CRC),
// so a transport that flags frame ends adds nothing here.
//
// -----------------------------------------------------------------------------
// Frame format - all multi-byte fields big endian
// -----------------------------------------------------------------------------
//   0      0xA5                 magic, re-syncs after a dropped byte
//   1      cmd
//   2      len[15:8]            payload length in bytes
//   3      len[7:0]
//   4..    payload
//   4+len  crc8                 over bytes 1 .. 4+len-1 (cmd, len, payload)
//
//   0x01 WRITE_W  payload = [target][addr_hi][addr_lo] + 32*N data bytes
//                 target[1:0] selects the region.  One 256-bit row per 32 bytes.
//   0x02 WRITE_A  payload = [addr_hi][addr_lo] + 2*N data bytes
//                 Broadcast to all four regions by the engine.
//   0x03 RUN      empty.  Refused unless weights_ready.
//   0x04 STATUS   empty.  Replies 8 bytes:
//                 [0] weights_ready [1] busy [2] err_code [3] any_error [4..7] 0
//   0x05 READ_OUT payload = [lane_start][nlanes-1]
//                 Replies nlanes*4 bytes, the byte order result_readout already
//                 produces (little endian within each 32-bit lane).
//
// The row/value count is implied by the length field, so no redundant count byte
// is needed in the payload.
//
// Error codes (sticky until a frame passes CRC)
//   0x00 OK  0x01 ERR_CRC  0x02 ERR_NOT_LOADED  0x03 ERR_BAD_CMD  0x04 ERR_BAD_ARG
// -----------------------------------------------------------------------------

module moe_loader (
    input                       clk,
    input                       rst_n,

    // AXI4-Stream sink: host -> FPGA
    input      [7:0]            s_axis_tdata,
    input                       s_axis_tvalid,
    output                      s_axis_tready,
    input                       s_axis_tlast,

    // AXI4-Stream source: FPGA -> host
    output     [7:0]            m_axis_tdata,
    output                      m_axis_tvalid,
    input                       m_axis_tready,
    output                      m_axis_tlast,

    // weight load port
    output reg                  w_wr_en,
    output reg [1:0]            w_wr_region,
    output reg [`H_ADDR_W-1:0]  w_wr_addr,
    output reg [`REGION_WCODE_W-1:0] w_wr_data,

    // activation load port
    output reg                  a_wr_en,
    output reg [`H_ADDR_W-1:0]  a_wr_addr,
    output reg [`ACT_W-1:0]     a_wr_data,

    // engine
    output reg                  gemv_start,
    input                       gemv_busy,
    input                       gemv_done,

    // result readout
    output reg                  rd_start,
    output reg [`E_ADDR_W-1:0]  rd_start_lane,
    output reg                  rd_pause,
    input                       rd_valid,
    input      [`E_ADDR_W-1:0]  rd_lane,
    input      [1:0]            rd_byte,
    input      [7:0]            rd_data,
    input                       rd_busy,

    // weight readback (narrow: the row is selected and serialised inside
    // gemv_engine, next to the banks, so no wide bus crosses the die)
    output reg                  rb_start,
    output reg     [1:0]        rb_region,
    output reg     [`H_ADDR_W-1:0] rb_addr,
    output reg     [15:0]       rb_nrows,
    output                      rb_byte_ready,
    input          [7:0]        rb_byte_out,
    input                       rb_byte_valid,
    input                       rb_done,

    // status
    output reg                  weights_ready,
    output reg                  act_valid,
    output                      busy,
    output reg [7:0]            err_code
);

    // ------------------------------------------------------------------
    localparam [7:0] CMD_WRITE_W = 8'h01;
    localparam [7:0] CMD_WRITE_A = 8'h02;
    localparam [7:0] CMD_RUN     = 8'h03;
    localparam [7:0] CMD_STATUS  = 8'h04;
    localparam [7:0] CMD_READOUT = 8'h05;
    // Read a weight row back out.  Payload: region, addr_hi, addr_lo, nrows-1.
    // Reply: nrows x 32 bytes, most significant byte of each row first, so the
    // result lines up directly with the .mem file the host loaded from.
    localparam [7:0] CMD_READ_W  = 8'h06;

    localparam [7:0] E_OK        = 8'h00;
    localparam [7:0] E_CRC       = 8'h01;
    localparam [7:0] E_NOTLOADED = 8'h02;
    localparam [7:0] E_BADCMD    = 8'h03;
    localparam [7:0] E_BADARG    = 8'h04;
    localparam [7:0] E_NODATA    = 8'h05;

    localparam [2:0] P_MAGIC   = 3'd0;
    localparam [2:0] P_CMD     = 3'd1;
    localparam [2:0] P_LEN_HI  = 3'd2;
    localparam [2:0] P_LEN_LO  = 3'd3;
    localparam [2:0] P_PAYLOAD = 3'd4;
    localparam [2:0] P_CRC     = 3'd5;
    localparam [2:0] P_EXEC    = 3'd6;
    localparam [2:0] P_REPLY   = 3'd7;

    reg [2:0]  st;

    // ------------------------------------------------------------------
    // CRC-8, polynomial 0x07, init 0, no reflection, no final xor.
    // Every Gigabit Ethernet MAC runs CRC32 byte-at-a-time at 125 MHz, so eight
    // bits of the same shape at 200 MHz is not a timing concern.
    // ------------------------------------------------------------------
    function [7:0] crc8;
        input [7:0] crc;
        input [7:0] din;
        integer i;
        reg [7:0] c;
        begin
            c = crc ^ din;
            for (i = 0; i < 8; i = i + 1)
                c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
            crc8 = c;
        end
    endfunction

    // ------------------------------------------------------------------
    // Parser state
    // ------------------------------------------------------------------
    reg [7:0]  cmd;
    reg [15:0] plen;
    reg [15:0] bcnt;
    reg [7:0]  crc;

    reg [1:0]            tgt_region;
    reg [7:0]            addr_hi;
    reg [`H_ADDR_W-1:0]  base_addr;

    reg [`REGION_WCODE_W-1:0] w_shift;
    reg [5:0]            w_bcnt;

    reg [`ACT_W-1:0]     a_shift;
    reg                  a_bcnt;

    reg [15:0]           rd_bytes_left;
    reg                  discard;

    // Status reply: preloaded word, shifted out low byte first.
    reg [63:0]           stat_word;
    reg [3:0]            stat_left;

    // ------------------------------------------------------------------
    // Reply FIFO - 32 x 8.  Only exists to decouple the readout (a byte every 6
    // clocks) from a slow transport (UART: a byte every 1736 clocks).
    // ------------------------------------------------------------------
    localparam FIFO_AW = 5;
    localparam FIFO_D  = 1 << FIFO_AW;

    reg [7:0]          fifo [0:FIFO_D-1];
    reg [FIFO_AW-1:0]  fifo_wp, fifo_rp;
    reg [FIFO_AW:0]    fifo_cnt;

    wire fifo_empty = (fifo_cnt == 0);
    wire fifo_full  = (fifo_cnt == FIFO_D);
    wire fifo_room  = (fifo_cnt < FIFO_D - 4);

    // ------------------------------------------------------------------
    // Stream interfaces
    // ------------------------------------------------------------------
    assign m_axis_tdata  = fifo[fifo_rp];
    assign m_axis_tvalid = !fifo_empty;
    assign m_axis_tlast  = 1'b0;

    // The parser consumes at most one byte per cycle.  It only stops accepting
    // while a reply is being emitted, because a host that is mid-conversation
    // should not be pushing a new command into the parser anyway.
    assign s_axis_tready = (st != P_REPLY);

    wire take_byte = s_axis_tvalid && s_axis_tready;
    wire [7:0] din = s_axis_tdata;

    // ------------------------------------------------------------------
    // Assembly: the last byte of a group is still on din, the earlier ones are
    // in the shift register.
    // ------------------------------------------------------------------
    wire [`REGION_WCODE_W-1:0] w_row_full = {w_shift[`REGION_WCODE_W-9:0], din};
    wire [`ACT_W-1:0]          a_val_full = {a_shift[`ACT_W-9:0], din};

    // Data byte index within the payload (payload header bytes are consumed
    // first, and their count differs per command).
    wire [15:0] w_idx = bcnt - 16'd3;      // WRITE_W: 3 header bytes
    wire [15:0] a_idx = bcnt - 16'd2;      // WRITE_A: 2 header bytes

    wire w_data_phase = (cmd == CMD_WRITE_W) && (bcnt >= 16'd3);
    wire a_data_phase = (cmd == CMD_WRITE_A) && (bcnt >= 16'd2);

    wire w_row_done = w_data_phase && (w_bcnt == 6'd31);
    wire a_val_done = a_data_phase && a_bcnt;

    // ------------------------------------------------------------------
    // Reply push
    // ------------------------------------------------------------------
    // A readout byte is taken only when the readout actually ADVANCES.
    //
    // rd_valid alone is not enough.  When rd_pause freezes the readout, rd_valid
    // and rd_data both hold their last value, so "push while rd_valid" pushed the
    // same byte on every cycle the pause lasted.  On the JTAG-AXI path a reply
    // byte arrives roughly once per millisecond while the readout offers one per
    // six clocks, so the pause is asserted almost all the time and the reply came
    // back as B7 B7 B7 B7 ... instead of four different bytes.
    //
    // A byte is uniquely identified by (rd_lane, rd_byte), and those change on
    // every advance, so watching them for a change turns "valid" into "a new byte
    // is here" without touching the readout's interface.  In the fast case
    // (simulation, where the pause is never asserted) they change every cycle and
    // the behaviour is identical to before.
    reg [`E_ADDR_W-1:0] rd_prev_lane;
    reg [1:0]           rd_prev_byte;
    reg                 rd_have_prev;

    wire rd_advance = rd_valid &&
                      (!rd_have_prev ||
                       (rd_lane != rd_prev_lane) ||
                       (rd_byte != rd_prev_byte));

    wire status_push = (st == P_REPLY) && (cmd == CMD_STATUS)  &&
                       (stat_left != 4'd0) && !fifo_full;
    wire result_push = (st == P_REPLY) && (cmd == CMD_READOUT) &&
                       rd_advance && (rd_bytes_left != 16'd0) && !fifo_full;

    // ---------------- weight readback -------------------------------
    // rb_start / rb_region / rb_addr / rb_nrows are ports (declared above) that
    // drive gemv_engine.  The engine serialises the row itself and hands back one
    // byte per accepted handshake.
    //
    // One-entry skid buffer, and it is load-bearing:
    //
    // rb_byte_valid arrives from gemv_engine, on the far side of the die, and it
    // originally fed fifo_push directly - which drives fifo_cnt's clock enable.
    // That made the loader's FIFO push path the worst setup path in the design
    // (-0.034 ns, FSM_sequential_st_reg[2] -> fifo_cnt_reg[0]/CE) and took the
    // build from +0.190 ns to failing.  Parking the byte in a local register
    // keeps the long net off that path: the far signal now only sets a local flop,
    // and everything downstream of it is local.
    //
    // Throughput becomes one byte per two cycles, which does not matter here: a
    // row is 32 bytes and the JTAG link costs about a millisecond per byte.
    reg        rb_v_q;
    reg [7:0]  rb_d_q;

    wire rb_take = rb_byte_valid && !rb_v_q;   // producer has a byte, slot is free
    assign rb_byte_ready = !rb_v_q;            // accept while the slot is free
    wire rb_push = rb_v_q && fifo_room;        // entirely local, short

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rb_v_q <= 1'b0;
            rb_d_q <= 8'd0;
        end else begin
            if (rb_take) rb_d_q <= rb_byte_out;
            // take and push are mutually exclusive: take needs an empty slot,
            // push needs a full one.
            if (rb_take)      rb_v_q <= 1'b1;
            else if (rb_push) rb_v_q <= 1'b0;
        end
    end

    wire fifo_push   = status_push || result_push || rb_push;
    wire [7:0] push_data = status_push ? stat_word[7:0] :
                           rb_push     ? rb_d_q      : rd_data;

    // ------------------------------------------------------------------
    // Reply FIFO write port, REGISTERED
    // ------------------------------------------------------------------
    // fifo_push is a three-way OR over state comparisons, and it drives the clock
    // enable of every FIFO data flop.  Measured, it was the only setup path in the
    // entire design anywhere near the limit:
    //
    //   +0.049 ns, 4 LUT levels, u_loader/FSM_sequential_st_reg[2] -> fifo_reg[*]/CE
    //
    // while the next worst path in the design had +3.940 ns and everything else -
    // engine, readout, memories - had 27 ns or more.  So one path was setting the
    // whole design's timing, and it was a control path, not a datapath.
    //
    // Registering the write port turns it into a flop-to-CE hop with no logic at
    // all.  The cost is one cycle of latency on a reply byte, which nothing here
    // can notice: the readout spends six cycles per byte and the host polls over
    // JTAG at millisecond scale.
    //
    // Cannot overflow: the registered write was decided using the room available
    // one cycle earlier, and occupancy can only fall during that cycle (a pop from
    // the AXI side), never rise - pushes are at most one per cycle and this IS the
    // only push path.  So a registered write never sees a full FIFO.
    //
    // The sources keep using the combinational *_push signals, so stat_left,
    // rd_bytes_left and rb_v_q advance on the cycle the byte is captured rather
    // than the cycle it lands.  That is the correct pairing: push_data is captured
    // on the same edge into fifo_wdata_q.
    reg        fifo_wen_q;
    reg [7:0]  fifo_wdata_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wen_q   <= 1'b0;
            fifo_wdata_q <= 8'd0;
        end else begin
            fifo_wen_q   <= fifo_push;
            fifo_wdata_q <= push_data;
        end
    end

    wire finish_status  = (cmd == CMD_STATUS)  && (stat_left == 4'd0) && (fifo_cnt == 0);
    wire finish_readout = (cmd == CMD_READOUT) && (rd_bytes_left == 16'd0) &&
                          (fifo_cnt == 0) && !rd_busy;

    // The readback serialiser lives inside gemv_engine, not here.
    //
    // It used to be instantiated in this file, which meant the whole 256-bit row
    // had to travel from the weight banks through expert_engine, moe_proto_top and
    // moe_proto_board to reach it.  That added a second far-away load to every
    // bank output and pinned the loader in the middle of a four-way 256-bit star
    // while it also had to stay near the AXI bridge, the UART and its own state
    // machine.  Resource use did not move (-114 LUT, -141 FF) but route_design
    // went from 499 s to over two hours.  Only narrow signals cross now.

    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= P_MAGIC;
            cmd           <= 8'd0;
            plen          <= 16'd0;
            bcnt          <= 16'd0;
            crc           <= 8'd0;
            tgt_region    <= 2'd0;
            addr_hi       <= 8'd0;
            base_addr     <= {`H_ADDR_W{1'b0}};
            w_shift       <= {`REGION_WCODE_W{1'b0}};
            w_bcnt        <= 6'd0;
            a_shift       <= {`ACT_W{1'b0}};
            a_bcnt        <= 1'b0;
            rd_bytes_left <= 16'd0;
            rd_prev_lane  <= {`E_ADDR_W{1'b0}};
            rd_prev_byte  <= 2'd0;
            rd_have_prev  <= 1'b0;
            rb_start      <= 1'b0;
            rb_region     <= 2'd0;
            rb_addr       <= {`H_ADDR_W{1'b0}};
            rb_nrows      <= 16'd0;
            discard       <= 1'b0;
            stat_word     <= 64'd0;
            stat_left     <= 4'd0;

            // The FIFO pointers must be reset here too.  When they were left out
            // they powered up as X, so every reply byte read out of fifo[fifo_rp]
            // was X while the occupancy counter (reset in its own block) happily
            // counted pushes and pops.  The symptom looked like "data arrives but
            // is X", which points at the memory rather than at the pointer.
            fifo_wp       <= {FIFO_AW{1'b0}};
            fifo_rp       <= {FIFO_AW{1'b0}};

            w_wr_en       <= 1'b0;
            w_wr_region   <= 2'd0;
            w_wr_addr     <= {`H_ADDR_W{1'b0}};
            w_wr_data     <= {`REGION_WCODE_W{1'b0}};
            a_wr_en       <= 1'b0;
            a_wr_addr     <= {`H_ADDR_W{1'b0}};
            a_wr_data     <= {`ACT_W{1'b0}};

            gemv_start    <= 1'b0;
            rd_start      <= 1'b0;
            rd_start_lane <= {`E_ADDR_W{1'b0}};
            // rd_pause is NOT reset here.  It has its own always block at the
            // bottom of the module, and driving it from both places made it a
            // multi-driven net: synthesis kept the constant driver, so rd_pause
            // was tied to 0 and the readout could never be throttled - a
            // READ_OUT of 1024 bytes would then overrun the reply FIFO.

            weights_ready <= 1'b0;
            act_valid      <= 1'b0;
            err_code      <= E_OK;
        end else begin
            // one-cycle strobes
            w_wr_en    <= 1'b0;
            a_wr_en    <= 1'b0;
            gemv_start <= 1'b0;

            // ---------------- memory commits -------------------------
            if (w_row_done && take_byte) begin
                w_wr_en     <= 1'b1;
                w_wr_region <= tgt_region;
                w_wr_addr   <= base_addr;
                w_wr_data   <= w_row_full;
                base_addr   <= base_addr + 1'b1;
            end
            if (a_val_done && take_byte) begin
                a_wr_en   <= 1'b1;
                a_wr_addr <= base_addr;
                a_wr_data <= a_val_full;
                base_addr <= base_addr + 1'b1;
            end

            // ---------------- reply FIFO -----------------------------
            // Uses the REGISTERED write port - see the note where fifo_wen_q is
            // declared.  Everything here is driven by a flop, so the only logic on
            // the FIFO's clock-enable path is gone.
            if (fifo_wen_q) begin
                fifo[fifo_wp] <= fifo_wdata_q;
                fifo_wp       <= fifo_wp + 1'b1;
            end
            if (status_push) begin
                stat_word <= {8'd0, stat_word[63:8]};
                stat_left <= stat_left - 4'd1;
            end
            if (result_push) begin
                rd_bytes_left <= rd_bytes_left - 16'd1;
                rd_prev_lane  <= rd_lane;
                rd_prev_byte  <= rd_byte;
                rd_have_prev  <= 1'b1;
            end
            if (!fifo_empty && m_axis_tready) begin
                fifo_rp <= fifo_rp + 1'b1;
            end

            // ---------------- parser FSM -----------------------------
            case (st)
                // Byte 0: magic.  Everything else is ignored, so a stream that
                // starts mid-frame or loses a byte re-syncs on the next 0xA5
                // without needing a reset.
                P_MAGIC: begin
                    discard <= 1'b0;
                    if (take_byte && din == 8'hA5) begin
                        crc  <= 8'd0;
                        plen <= 16'd0;
                        bcnt <= 16'd0;
                        st   <= P_CMD;
                    end
                end

                // Byte 1: command.  CRC starts here.
                P_CMD: begin
                    if (take_byte) begin
                        cmd <= din;
                        crc <= crc8(8'd0, din);
                        if (din == CMD_WRITE_W || din == CMD_WRITE_A ||
                            din == CMD_RUN     || din == CMD_STATUS ||
                            din == CMD_READOUT || din == CMD_READ_W) begin
                            st <= P_LEN_HI;
                        end else begin
                            err_code <= E_BADCMD;
                            st       <= P_MAGIC;      // length would be meaningless
                        end
                    end
                end

                P_LEN_HI: begin
                    if (take_byte) begin
                        plen[15:8] <= din;
                        crc        <= crc8(crc, din);
                        st         <= P_LEN_LO;
                    end
                end

                P_LEN_LO: begin
                    if (take_byte) begin
                        plen[7:0] <= din;
                        crc       <= crc8(crc, din);
                        bcnt      <= 16'd0;
                        w_bcnt    <= 6'd0;
                        a_bcnt    <= 1'b0;
                        st        <= (plen[15:8] == 8'd0 && din == 8'd0) ? P_CRC : P_PAYLOAD;
                    end
                end

                P_PAYLOAD: begin
                    if (take_byte) begin
                        crc  <= crc8(crc, din);
                        bcnt <= bcnt + 16'd1;

                        if (cmd == CMD_WRITE_W) begin
                            case (bcnt)
                                16'd0: tgt_region <= din[1:0];
                                16'd1: addr_hi    <= din;
                                16'd2: base_addr  <= {addr_hi[`H_ADDR_W-9:0], din};
                                default: begin
                                    w_shift <= w_row_full;
                                    // Must wrap per row, not per frame.  Leaving
                                    // it to keep counting past 31 meant "w_bcnt
                                    // == 31" matched exactly once per frame, so
                                    // only the first row of each frame was ever
                                    // committed and the other 1023 stayed zero.
                                    // The frame still passed CRC, so the symptom
                                    // was plausible-but-wrong results.
                                    w_bcnt  <= w_row_done ? 6'd0 : (w_bcnt + 6'd1);
                                end
                            endcase
                        end else if (cmd == CMD_WRITE_A) begin
                            case (bcnt)
                                16'd0: addr_hi   <= din;
                                16'd1: base_addr <= {addr_hi[`H_ADDR_W-9:0], din};
                                default: begin
                                    a_shift <= a_val_full;
                                    a_bcnt  <= ~a_bcnt;
                                end
                            endcase
                        end else if (cmd == CMD_READOUT) begin
                            case (bcnt)
                                16'd0: rd_start_lane <= din;
                                16'd1: rd_bytes_left <= {din, 2'b00} + 16'd4;
                                default: ;
                            endcase
                        end else if (cmd == CMD_READ_W) begin
                            // region, addr_hi, addr_lo, nrows-1
                            case (bcnt)
                                16'd0: rb_region <= din[1:0];
                                16'd1: rb_addr[9:8] <= din[1:0];
                                16'd2: rb_addr[7:0] <= din;
                                16'd3: rb_nrows <= {8'd0, din} + 16'd1;
                                default: ;
                            endcase
                        end

                        if (bcnt + 16'd1 == plen) st <= P_CRC;
                    end
                end

                // CRC byte.  This is where the streaming loader's guarantee has
                // to be stated carefully:
                //
                //   The payload has ALREADY been written to the memories by the
                //   time the CRC arrives - there is no 128 KiB buffer to hold it
                //   first.  So the frame cannot be "rolled back".
                //
                //   What makes the CRC worth having is therefore invalidation,
                //   not rollback: a bad CRC clears the validity flag of exactly
                //   the thing that frame was writing, and every following RUN is
                //   refused until the host reloads it.  A corrupted transfer can
                //   then never produce a plausible-but-wrong result - which is
                //   the whole point, because that is indistinguishable from an
                //   arithmetic bug.
                P_CRC: begin
                    if (take_byte) begin
                        if (din == crc) begin
                            // err_code is deliberately NOT cleared here: STATUS's own frame
                            // passes CRC, so clearing it would let the command that asks 'what went
                            // wrong' erase the answer before the reply is built.  It is cleared only
                            // by a successful WRITE_W / WRITE_A, in P_EXEC.
                            st       <= P_EXEC;
                        end else begin
                            err_code <= E_CRC;
                            if (cmd == CMD_WRITE_W) weights_ready <= 1'b0;
                            if (cmd == CMD_WRITE_A) act_valid     <= 1'b0;
                            st <= P_MAGIC;
                        end
                    end
                end

                P_EXEC: begin
                    if (cmd == CMD_WRITE_W) begin
                        weights_ready <= 1'b1;
                        err_code      <= E_OK;
                        st            <= P_MAGIC;
                    end else if (cmd == CMD_WRITE_A) begin
                        act_valid <= 1'b1;
                        err_code  <= E_OK;
                        st        <= P_MAGIC;
                    end else if (cmd == CMD_RUN) begin
                        if (!weights_ready) begin
                            err_code <= E_NOTLOADED;
                            st       <= P_MAGIC;
                        end else if (!act_valid) begin
                            err_code <= E_NODATA;
                            st       <= P_MAGIC;
                        end else begin
                            gemv_start <= 1'b1;
                            st         <= P_MAGIC;
                        end
                    end else if (cmd == CMD_STATUS) begin
                        stat_word <= {8'd0, 8'd0, 8'd0, 8'd0,
                                      {7'd0, (err_code != E_OK)},
                                      err_code,
                                      {7'd0, act_valid},
                                      7'd0, weights_ready};
                        stat_left <= 4'd8;
                        st        <= P_REPLY;
                    end else if (cmd == CMD_READOUT) begin
                        if (rd_bytes_left == 16'd0) begin
                            err_code <= E_BADARG;
                            st       <= P_MAGIC;
                        end else begin
                            rd_start     <= 1'b1;
                            // Force the first byte after a restart to look new:
                            // otherwise, if it happens to share (lane, byte) with
                            // the last byte of the previous readout, it would be
                            // mistaken for a repeat and dropped.
                            rd_have_prev <= 1'b0;
                            st           <= P_REPLY;
                        end
                    end else if (cmd == CMD_READ_W) begin
                        if (rb_nrows == 16'd0) begin
                            err_code <= E_BADARG;
                            st       <= P_MAGIC;
                        end else begin
                            // The readback engine drives the weight banks' read
                            // port, so this must not overlap a GEMV.
                            rb_start <= 1'b1;
                            st       <= P_REPLY;
                        end
                    end
                end

                P_REPLY: begin
                    rd_start <= 1'b0;
                    rb_start <= 1'b0;
                    if (cmd == CMD_STATUS) begin
                        if (finish_status) st <= P_MAGIC;
                    end else if (cmd == CMD_READ_W) begin
                        if (rb_done) st <= P_MAGIC;
                    end else begin
                        // Once the requested bytes are all queued, stop
                        // forwarding and let the readout sweep to the end so it
                        // returns to idle and can be restarted next time.
                        if (rd_bytes_left == 16'd0) discard <= 1'b1;
                        if (finish_readout) st <= P_MAGIC;
                    end
                end

                default: st <= P_MAGIC;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // FIFO occupancy - single source of truth, matching the push/pop above
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_cnt <= {(FIFO_AW+1){1'b0}};
        end else begin
            case ({fifo_wen_q, (!fifo_empty && m_axis_tready)})
                2'b10:   fifo_cnt <= fifo_cnt + 1'b1;
                2'b01:   fifo_cnt <= fifo_cnt - 1'b1;
                default: fifo_cnt <= fifo_cnt;
            endcase
        end
    end

    // Pause the readout when the FIFO cannot take more.  This is what lets a
    // slow transport throttle a fast readout with no data loss and no big buffer.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rd_pause <= 1'b0;
        else        rd_pause <= (st == P_REPLY) && (cmd == CMD_READOUT) &&
                                (rd_bytes_left != 16'd0) && !fifo_room;
    end

    // Anything being parsed, or the engine running, counts as busy.
    assign busy = (st != P_MAGIC) || gemv_busy;

    // Unused, kept so the port list matches the AXI-Stream shape.
    wire unused_tlast = s_axis_tlast;

endmodule
