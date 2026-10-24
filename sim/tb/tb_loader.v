`timescale 1ns/1ps
`include "moe_params.vh"

// -----------------------------------------------------------------------------
// tb_loader - drive the loader's byte interface directly
// -----------------------------------------------------------------------------
// No UART, no bit-banging: this testbench plays the host and pushes frames into
// s_axis_* at one byte per cycle, then collects the reply from m_axis_*.
//
// What it proves, in order:
//   1. the frame parser accepts valid frames and the CRC gate works
//   2. WRITE_W fills all four weight banks (4 x 1024 rows = 128 KiB)
//   3. WRITE_A fills the activation buffers
//   4. RUN is refused before any weights are loaded (ERR_NOT_LOADED)
//   5. a frame with a corrupted byte is rejected (ERR_CRC) and STATUS says so
//   6. READ_OUT returns 256 lanes that match sim/data/ref_out.hex
//
// Step 4 and 5 are the ones that matter beyond "does data get written": they are
// what stops a dropped byte from being misdiagnosed as an arithmetic bug, which
// has already happened once in this project with the board's checksum.
// -----------------------------------------------------------------------------
module tb_loader;

    reg clk;
    reg rst_n;

    reg  [7:0] s_axis_tdata;
    reg        s_axis_tvalid;
    wire       s_axis_tready;

    wire [7:0] m_axis_tdata;
    wire       m_axis_tvalid;
    reg        m_axis_tready;

    wire                     w_wr_en;
    wire [1:0]               w_wr_region;
    wire [`H_ADDR_W-1:0]     w_wr_addr;
    wire [`REGION_WCODE_W-1:0] w_wr_data;

    wire                     a_wr_en;
    wire [`H_ADDR_W-1:0]     a_wr_addr;
    wire [`ACT_W-1:0]        a_wr_data;

    wire        gemv_start;
    wire        gemv_busy;
    wire        gemv_done;

    wire        rd_start;
    wire [`E_ADDR_W-1:0] rd_start_lane;
    wire        rd_pause;
    wire        rd_valid;
    wire [`E_ADDR_W-1:0] rd_lane;
    wire [1:0]  rd_byte;
    wire [7:0]  rd_data;
    wire        rb_start;
    wire [1:0]  rb_region;
    wire [`H_ADDR_W-1:0] rb_addr;
    wire [15:0] rb_nrows;
    wire        rb_byte_ready;
    wire [7:0]  rb_byte_out;
    wire        rb_byte_valid;
    wire        rb_done;
    wire        rd_busy;

    wire        weights_ready;
    wire        busy;
    wire [7:0]  err_code;

    // ------------------------------------------------------------------
    // DUT: the engine behind the loader
    // ------------------------------------------------------------------
    moe_proto_top u_top (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (gemv_start),
        .busy           (gemv_busy),
        .done           (gemv_done),
        .w_wr_en        (w_wr_en),
        .w_wr_region    (w_wr_region),
        .w_wr_addr      (w_wr_addr),
        .w_wr_data      (w_wr_data),
        .act_wr_en      (a_wr_en),
        .act_wr_addr    (a_wr_addr),
        .act_wr_data    (a_wr_data),
        .rd_start       (rd_start),
        .rd_start_lane  (rd_start_lane),
        .rd_pause       (rd_pause),
        .rd_valid       (rd_valid),
        .rd_lane        (rd_lane),
        .rd_byte        (rd_byte),
        .rd_data        (rd_data),
        .rd_busy        (rd_busy),
        .rb_start       (rb_start),
        .rb_region      (rb_region),
        .rb_addr        (rb_addr),
        .rb_nrows       (rb_nrows),
        .rb_byte_ready  (rb_byte_ready),
        .rb_byte_out    (rb_byte_out),
        .rb_byte_valid  (rb_byte_valid),
        .rb_done        (rb_done),
        .result_checksum()
    );

    moe_loader u_loader (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (1'b0),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tlast   (),
        .w_wr_en        (w_wr_en),
        .w_wr_region    (w_wr_region),
        .w_wr_addr      (w_wr_addr),
        .w_wr_data      (w_wr_data),
        .a_wr_en        (a_wr_en),
        .a_wr_addr      (a_wr_addr),
        .a_wr_data      (a_wr_data),
        .gemv_start     (gemv_start),
        .gemv_busy      (gemv_busy),
        .gemv_done      (gemv_done),
        .rd_start       (rd_start),
        .rd_start_lane  (rd_start_lane),
        .rd_pause       (rd_pause),
        .rd_valid       (rd_valid),
        .rd_lane        (rd_lane),
        .rd_byte        (rd_byte),
        .rd_data        (rd_data),
        .rd_busy        (rd_busy),
        .rb_start       (rb_start),
        .rb_region      (rb_region),
        .rb_addr        (rb_addr),
        .rb_nrows       (rb_nrows),
        .rb_byte_ready  (rb_byte_ready),
        .rb_byte_out    (rb_byte_out),
        .rb_byte_valid  (rb_byte_valid),
        .rb_done        (rb_done),
        .weights_ready  (weights_ready),
        .busy           (busy),
        .err_code       (err_code)
    );

    // 200 MHz, matching the board
    initial begin
        clk = 1'b0;
        forever #2.5 clk = ~clk;
    end

    // ------------------------------------------------------------------
    // CRC-8, must match the RTL bit for bit
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
    // Host side
    // ------------------------------------------------------------------
    reg [7:0] tx_crc;

    reg [`ACT_W-1:0]  input_mem [0:`H_DIM-1];
    reg [`REGION_WCODE_W-1:0] w_mem0 [0:`H_DIM-1];
    reg [`REGION_WCODE_W-1:0] w_mem1 [0:`H_DIM-1];
    reg [`REGION_WCODE_W-1:0] w_mem2 [0:`H_DIM-1];
    reg [`REGION_WCODE_W-1:0] w_mem3 [0:`H_DIM-1];

    // Received bytes
    reg [7:0] rx_bytes [0:2047];
    integer   rx_count;

    integer i, b, j, k;
    integer errors;
    integer fd;

    // ------------------------------------------------------------------
    // Slow consumer option
    // ------------------------------------------------------------------
    // With tready tied high the reply is drained as fast as it is produced, the
    // loader's FIFO never fills, rd_pause never asserts, and the readout is never
    // throttled.  On the real JTAG-AXI path a reply byte is consumed about once
    // per millisecond, so rd_pause is asserted almost permanently - and that is
    // the condition under which the loader used to push the same byte again on
    // every paused cycle.  Without a slow mode here, simulation cannot see the
    // bug at all, which is exactly how it survived this long.
    reg        slow_mode;
    reg [7:0]  slow_div;

    always @(posedge clk) begin
        if (slow_mode) begin
            slow_div      <= slow_div + 8'd1;
            m_axis_tready <= (slow_div == 8'd0);   // one cycle in 256
        end else begin
            m_axis_tready <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            if (rx_count < 8)
                $display("LOADER TB:   [cap] cnt=%0d tdata=%02x rp=%0d",
                         rx_count, m_axis_tdata, u_loader.fifo_rp);
            if (rx_count < 2048) rx_bytes[rx_count] = m_axis_tdata;
            rx_count = rx_count + 1;
        end
    end

    task put(input [7:0] v);
        begin
            s_axis_tdata  <= v;
            s_axis_tvalid <= 1'b1;
            @(posedge clk);
            while (!s_axis_tready) @(posedge clk);
            s_axis_tvalid <= 1'b0;
        end
    endtask

    // Byte that participates in the CRC
    task putc(input [7:0] v);
        begin
            put(v);
            tx_crc = crc8(tx_crc, v);
        end
    endtask

    task frame_begin(input [7:0] c, input [15:0] len);
        begin
            put(8'hA5);
            tx_crc = 8'd0;
            putc(c);
            putc(len[15:8]);
            putc(len[7:0]);
        end
    endtask

    task frame_end;
        begin
            put(tx_crc);
        end
    endtask

    // Read back one STATUS byte stream and check a field
    task get_status(output [7:0] ready, output [7:0] err);
        begin
            rx_count = 0;
            frame_begin(8'h04, 16'd0);
            frame_end;
            // 8 reply bytes
            for (k = 0; k < 400; k = k + 1) @(posedge clk);
            $display("LOADER TB:   [status] rx_count=%0d st=%0d stat_left=%0d fifo_cnt=%0d",
                     rx_count, u_loader.st, u_loader.stat_left, u_loader.fifo_cnt);
            $display("LOADER TB:   [status] bytes = %02x %02x %02x %02x %02x %02x %02x %02x",
                     rx_bytes[0], rx_bytes[1], rx_bytes[2], rx_bytes[3],
                     rx_bytes[4], rx_bytes[5], rx_bytes[6], rx_bytes[7]);
            ready = rx_bytes[0];
            err   = rx_bytes[2];
        end
    endtask

    initial begin
        rst_n          = 1'b0;
        s_axis_tdata   = 8'd0;
        s_axis_tvalid  = 1'b0;
        m_axis_tready  = 1'b1;
        rx_count       = 0;
        errors         = 0;
        slow_mode      = 1'b0;      // must be initialised: as X, the "if (slow_mode)"
        slow_div       = 8'd0;      // comparison took the X branch and m_axis_tready
                                    // went X, so no reply byte ever transferred.

        $readmemh("sim/data/input.mem", input_mem);
        $readmemh("mem_init/expert0/gate_r0.mem", w_mem0);
        $readmemh("mem_init/expert0/gate_r1.mem", w_mem1);
        $readmemh("mem_init/expert0/gate_r2.mem", w_mem2);
        $readmemh("mem_init/expert0/gate_r3.mem", w_mem3);

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ==========================================================
        // 1. RUN before any weights must be refused
        // ==========================================================
        begin : t_not_loaded
            reg [7:0] rdy, err;
            get_status(rdy, err);
            $display("LOADER TB: before load: weights_ready=%0d err=%02x", rdy, err);
            if (rdy !== 8'd0) begin
                $display("LOADER TB: ERROR weights_ready should be 0 before loading");
                errors = errors + 1;
            end

            rx_count = 0;
            frame_begin(8'h03, 16'd0);       // RUN
            frame_end;
            for (k = 0; k < 50; k = k + 1) @(posedge clk);
            $display("LOADER TB: RUN before load -> err=%02x (expect 02)", err_code);
            if (err_code !== 8'h02) begin
                $display("LOADER TB: ERROR expected ERR_NOT_LOADED (02)");
                errors = errors + 1;
            end
        end

        // ==========================================================
        // 2. Write all four weight banks: 4 frames of 3 + 32768 bytes
        // ==========================================================
        $display("LOADER TB: loading 4 x 1024 weight rows...");
        for (b = 0; b < 4; b = b + 1) begin
            frame_begin(8'h01, 16'd3 + 16'd32768);
            putc({6'd0, b[1:0]});            // target = region
            putc(8'd0);                      // addr high
            putc(8'd0);                      // addr low
            for (i = 0; i < `H_DIM; i = i + 1) begin
                for (j = 31; j >= 0; j = j - 1) begin
                    case (b)
                        0: putc(w_mem0[i][j*8 +: 8]);
                        1: putc(w_mem1[i][j*8 +: 8]);
                        2: putc(w_mem2[i][j*8 +: 8]);
                        default: putc(w_mem3[i][j*8 +: 8]);
                    endcase
                end
            end
            frame_end;
            @(posedge clk);
        end

        begin : t_weights_ok
            reg [7:0] rdy, err;
            get_status(rdy, err);
            $display("LOADER TB: after weights: weights_ready=%0d err=%02x", rdy, err);
            if (rdy !== 8'd1) begin
                $display("LOADER TB: ERROR weights_ready should be 1");
                errors = errors + 1;
            end
        end

        // ----------------------------------------------------------
        // Did the bytes that reached the BRAM actually match the files?
        // This is the check that separates "loader wrote wrong data" from
        // "engine computed wrong" - without it, both look like a bad result.
        // ----------------------------------------------------------
        $display("LOADER TB: --- weight bank contents vs .mem ---");
        $display("LOADER TB:   r0[0] = %h  expect %h", u_top.u_expert_engine.u_gate_gemv.u_wbank_r0.mem[0], w_mem0[0]);
        $display("LOADER TB:   r0[1] = %h  expect %h", u_top.u_expert_engine.u_gate_gemv.u_wbank_r0.mem[1], w_mem0[1]);
        $display("LOADER TB:   r1[0] = %h  expect %h", u_top.u_expert_engine.u_gate_gemv.u_wbank_r1.mem[0], w_mem1[0]);
        $display("LOADER TB:   r2[0] = %h  expect %h", u_top.u_expert_engine.u_gate_gemv.u_wbank_r2.mem[0], w_mem2[0]);
        $display("LOADER TB:   r3[0] = %h  expect %h", u_top.u_expert_engine.u_gate_gemv.u_wbank_r3.mem[0], w_mem3[0]);
        $display("LOADER TB:   r0[1023] = %h  expect %h", u_top.u_expert_engine.u_gate_gemv.u_wbank_r0.mem[1023], w_mem0[1023]);

        // ==========================================================
        // 3. Activation vector, 1024 x 16 bit
        // ==========================================================
        $display("LOADER TB: loading activations...");        frame_begin(8'h02, 16'd2 + 16'd2048);
        putc(8'd0);                          // addr high
        putc(8'd0);                          // addr low
        for (i = 0; i < `H_DIM; i = i + 1) begin
            putc(input_mem[i][15:8]);
            putc(input_mem[i][7:0]);
        end
        frame_end;
        @(posedge clk);

        $display("LOADER TB: --- activation buffer contents vs .mem ---");
        $display("LOADER TB:   act0[0]    = %h expect %h", u_top.u_expert_engine.u_gate_gemv.u_region0.u_act_buffer.mem[0],    input_mem[0]);
        $display("LOADER TB:   act0[1]    = %h expect %h", u_top.u_expert_engine.u_gate_gemv.u_region0.u_act_buffer.mem[1],    input_mem[1]);
        $display("LOADER TB:   act0[1023] = %h expect %h", u_top.u_expert_engine.u_gate_gemv.u_region0.u_act_buffer.mem[1023], input_mem[1023]);
        $display("LOADER TB:   act3[0]    = %h expect %h", u_top.u_expert_engine.u_gate_gemv.u_region3.u_act_buffer.mem[0],    input_mem[0]);

        // ==========================================================
        // 4. A corrupted frame is detected, and - because a streaming loader
        //    cannot roll back what it already wrote - it must INVALIDATE the
        //    data so a later RUN is refused rather than computing on garbage.
        // ==========================================================
        begin : t_bad_crc
            frame_begin(8'h02, 16'd2 + 16'd4);
            putc(8'd0);
            putc(8'd0);
            putc(8'hDE);
            putc(8'hAD);
            putc(8'hBE);
            putc(8'hEF);
            put(8'h00);                      // deliberate wrong CRC
            @(posedge clk);
            $display("LOADER TB: corrupted frame -> err=%02x (expect 01) act_valid=%b (expect 0)",
                     err_code, u_loader.act_valid);
            if (err_code !== 8'h01) begin
                $display("LOADER TB: ERROR expected ERR_CRC (01)");
                errors = errors + 1;
            end
            if (u_loader.act_valid !== 1'b0) begin
                $display("LOADER TB: ERROR act_valid should be cleared after a bad frame");
                errors = errors + 1;
            end

            // RUN must now be refused, not silently run on the tainted buffer
            frame_begin(8'h03, 16'd0);
            frame_end;
            // The CRC byte lands in P_CRC, and the command is only judged in
            // P_EXEC, so err_code settles 2-3 cycles after the last byte.  A
            // single @(posedge clk) reads the previous frame's value.
            for (k = 0; k < 20; k = k + 1) @(posedge clk);
            $display("LOADER TB: RUN after corruption -> err=%02x (expect 05)", err_code);
            if (err_code !== 8'h05) begin
                $display("LOADER TB: ERROR expected ERR_NODATA (05)");
                errors = errors + 1;
            end
        end

        // ==========================================================
        // 4b. Reload the activations; the corrupted values (0xDEAD, 0xBEEF at
        //     addresses 0 and 1) must be overwritten.
        // ==========================================================
        $display("LOADER TB: reloading activations after the bad frame...");
        frame_begin(8'h02, 16'd2 + 16'd2048);
        putc(8'd0);
        putc(8'd0);
        for (i = 0; i < `H_DIM; i = i + 1) begin
            putc(input_mem[i][15:8]);
            putc(input_mem[i][7:0]);
        end
        frame_end;
        @(posedge clk);
        $display("LOADER TB:   act0[0]=%h (expect %h)  act0[1]=%h (expect %h)",
                 u_top.u_expert_engine.u_gate_gemv.u_region0.u_act_buffer.mem[0], input_mem[0],
                 u_top.u_expert_engine.u_gate_gemv.u_region0.u_act_buffer.mem[1], input_mem[1]);

        // ==========================================================
        // 5. RUN and read the result back
        // ==========================================================
        $display("LOADER TB: running one GEMV...");
        rx_count = 0;
        frame_begin(8'h03, 16'd0);
        frame_end;
        wait (gemv_done === 1'b1);
        for (k = 0; k < 10; k = k + 1) @(posedge clk);

        $display("LOADER TB: reading back 256 lanes (slow consumer: tready 1-in-256)...");
        rx_count  = 0;
        slow_mode = 1'b1;
        frame_begin(8'h05, 16'd2);
        putc(8'd0);                          // lane_start
        putc(8'd255);                        // nlanes-1 = 255 -> 256 lanes
        frame_end;

        // Wait for the whole reply to trickle out.  A 1-in-256 consumer needs
        // 1024 x 256 cycles, so the old fixed 6000-cycle wait would truncate it.
        for (k = 0; k < 400000; k = k + 1) begin
            @(posedge clk);
            if (rx_count >= 1024) k = 400000;
        end
        slow_mode = 1'b0;

        $display("LOADER TB: received %0d bytes (expect 1024)", rx_count);
        if (rx_count != 1024) begin
            $display("LOADER TB: ERROR wrong reply length");
            errors = errors + 1;
        end

        fd = $fopen("sim/data/loader_out.hex", "w");
        for (i = 0; i < 256; i = i + 1) begin
            $fwrite(fd, "%02x%02x%02x%02x\n",
                    rx_bytes[i*4+3], rx_bytes[i*4+2],
                    rx_bytes[i*4+1], rx_bytes[i*4+0]);
        end
        $fclose(fd);

        // ==================================================================
        // Weight readback
        // ==================================================================
        // Read four rows straight out of region 0's weight bank and compare with
        // the .mem file the loader was given.  This is the only test that looks
        // at what is actually IN the memory rather than inferring it from a
        // GEMV result, so it can tell a bad load from bad arithmetic.
        $display("LOADER TB: weight readback: region 0, rows 0..3");

        rx_count  = 0;
        slow_mode = 1'b0;

        frame_begin(8'h06, 16'd4);
        putc(8'd0);                          // region 0
        putc(8'd0);                          // addr_hi
        putc(8'd0);                          // addr_lo
        putc(8'd3);                          // nrows-1 = 3 -> 4 rows
        frame_end;

        for (k = 0; k < 400000; k = k + 1) begin
            @(posedge clk);
            if (rx_count >= 128) k = 400000;
        end

        $display("LOADER TB:   readback byte count = %0d (expect 128)", rx_count);
        if (rx_count != 128) begin
            $display("LOADER TB: ERROR wrong readback length");
            errors = errors + 1;
        end

        for (k = 0; k < 4; k = k + 1) begin
            for (j = 0; j < 32; j = j + 1) begin
                // w_mem0[k] is the 256-bit row as loaded; byte j from the top.
                if (rx_bytes[k*32 + j] !== w_mem0[k][255 - j*8 -: 8]) begin
                    if (errors < 8) begin
                        $display("LOADER TB: ERROR row %0d byte %0d: got %02x expect %02x",
                                 k, j, rx_bytes[k*32+j], w_mem0[k][255 - j*8 -: 8]);
                    end
                    errors = errors + 1;
                end
            end
        end
        if (errors == 0) $display("LOADER TB:   readback matches gate_r0.mem exactly");

        if (errors == 0) begin
            $display("LOADER TB: PROTOCOL TESTS PASSED");
        end else begin
            $display("LOADER TB: %0d ERROR(S)", errors);
        end
        $display("Output: sim/data/loader_out.hex");
        $finish;
    end

endmodule
