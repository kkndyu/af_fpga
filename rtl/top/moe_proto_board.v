`include "moe_params.vh"

// -----------------------------------------------------------------------------
// moe_proto_board
// -----------------------------------------------------------------------------
// ALINX AX7203B board level wrapper.
//
//   part  : xc7a200tfbg484-2
//   clock : 200 MHz differential oscillator on R4 / T4 (DIFF_SSTL15)
//   reset : rst_n on T6, active low (LVCMOS15)
//   led   : B13 / C13 / D14 / D15 (LVCMOS33), active LOW
//   uart  : on-board USB bridge, rx P20, tx N15 (LVCMOS33)
//
// Clock input style follows the factory led_test.v: a differential pair through
// IBUFDS, so the constraint file drives only sys_clk_p.
//
// -----------------------------------------------------------------------------
// V2 architecture: Ethernet-ready byte stream
// -----------------------------------------------------------------------------
// The board no longer self-starts from a ROM.  It is a passive device that waits
// for framed commands on a byte stream, and that byte stream is transport
// agnostic by design:
//
//     uart_rx  --\
//                 >-- mux --> moe_loader --> weight/activation ports, engine
//     jtag_axi --/             \--> reply --> mux --> uart_tx / AXI
//     (eth)   --/
//
// Two paths are wired today:
//
//   UART      : always present.  Slow (one byte per 1736 clocks at 115200) but it
//               needs no protocol stack and no extra clock, so it is the fallback
//               that always works.
//   JTAG-AXI  : compiled in only when WITH_JTAG_AXI is defined, because it needs
//               the jtag_axi IP (scripts/gen_jtag_axi.tcl).  It moves whole words
//               over the JTAG cable and needs no pins at all.
//
// Ethernet will attach at the same byte-stream mux once the MAC is written, which
// is the entire reason the loader was written against tdata/tvalid/tready rather
// than against a UART.
//
// Nothing here is initialised at configuration time: the weight and activation
// BRAMs come up empty and stay empty until a host loads them.
// -----------------------------------------------------------------------------
module moe_proto_board (
    input         sys_clk_p,
    input         sys_clk_n,
    input         rst_n,
    input         uart_rx,
    output        uart_tx,
    output [3:0]  led
);

    // ------------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------------
    //
    // THE BOARD OSCILLATOR IS 200 MHz, NOT 100 MHz.
    //
    // The factory design proves it: led_test.v counts 49_999_999 cycles for
    // "0.25 sec", which is only true at 200 MHz, and its own constraint file
    // says create_clock -period 5.000.
    //
    // An earlier build "closed timing" only because the build script overrode the
    // constraint to 10 ns - which changed the analysis target but not the
    // hardware.  The FPGA therefore ran the logic at twice the frequency it was
    // signed off for, and the checksum came out wrong.  RTL simulation and a
    // gate-level simulation of the routed netlist both produced the expected
    // value, which pinned the fault on timing rather than logic.
    //
    // The pipeline has since been reworked and 200 MHz now closes honestly.
    //
    //   DIV_BITS = 0  ->  /1  ->  200 MHz (current)
    //   DIV_BITS = 2  ->  /4  ->   50 MHz (the cautious first hardware run)
    //
    // Keep DIV_BITS and the XDC's create_generated_clock -divide_by in step;
    // build_moe.tcl checks them against each other and refuses to build if they
    // disagree.
    localparam DIV_BITS  = 0;

    localparam integer UART_CLK_FREQ  = 200_000_000;
    localparam integer UART_BAUD_RATE = 115_200;

    // LED blink, ~3 Hz at 200 MHz.
    localparam BLINK_BIT = 24;

    wire sys_clk_raw;
    wire clk_engine_raw;
    wire sys_clk;

    IBUFDS u_sys_clk_ibufds (
        .O  (sys_clk_raw),
        .I  (sys_clk_p),
        .IB (sys_clk_n)
    );

    generate
        if (DIV_BITS == 0) begin : g_no_div
            assign clk_engine_raw = sys_clk_raw;
        end else begin : g_div
            reg [DIV_BITS-1:0] div_cnt;
            reg                clk_div_q;

            always @(posedge sys_clk_raw or negedge rst_n) begin
                if (!rst_n) begin
                    div_cnt   <= {DIV_BITS{1'b0}};
                    clk_div_q <= 1'b0;
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                    if (div_cnt == 1'b1) clk_div_q <= ~clk_div_q;
                end
            end

            assign clk_engine_raw = clk_div_q;
        end
    endgenerate

    // A register driving a clock net needs a global buffer, otherwise the skew is
    // uncontrolled.  Naming it keeps the XDC's generated-clock reference
    // unambiguous.
    BUFG u_bufg_engine (
        .I (clk_engine_raw),
        .O (sys_clk)
    );

    // ------------------------------------------------------------------
    // UART
    // ------------------------------------------------------------------
    wire [7:0] u_rx_data;
    wire       u_rx_valid;
    wire       u_rx_ready;

    wire [7:0] u_tx_data;
    wire       u_tx_valid;
    wire       u_tx_ready;

    uart_rx #(
        .CLK_FREQ  (UART_CLK_FREQ),
        .BAUD_RATE (UART_BAUD_RATE)
    ) u_uart_rx (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .rx    (uart_rx),
        .data  (u_rx_data),
        .valid (u_rx_valid),
        .ready (u_rx_ready)
    );

    uart_tx #(
        .CLK_FREQ  (UART_CLK_FREQ),
        .BAUD_RATE (UART_BAUD_RATE)
    ) u_uart_tx (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .data  (u_tx_data),
        .valid (u_tx_valid),
        .ready (u_tx_ready),
        .tx    (uart_tx)
    );

    // ------------------------------------------------------------------
    // JTAG-to-AXI path (optional)
    // ------------------------------------------------------------------
    // Loader status, declared here because the AXI bridge below needs them.
    // They used to be declared further down, after the bridge, and the bridge's
    // status ports were left unconnected (.weights_ready() etc.).  That made the
    // bridge's STATUS *register* read back as all zeros forever, while the STATUS
    // *command* still worked - the command reply comes through the loader's own
    // byte FIFO, not through this register.  The result was a board where
    // "read STATUS at 0x04" always said healthy no matter what had gone wrong.
    wire        weights_ready, act_valid, busy;
    wire [7:0]  err_code;

    wire [7:0] a_tx_data;      // AXI master -> loader
    wire       a_tx_valid;
    wire       a_tx_ready;
    wire [7:0] a_rx_data;      // loader -> AXI master
    wire       a_rx_valid;
    wire       a_rx_ready;

`ifdef WITH_JTAG_AXI
    // AXI4-Lite from the jtag_axi master
    wire [31:0] s_awaddr, s_wdata, s_araddr, s_rdata;
    wire [3:0]  s_wstrb;
    wire        s_awvalid, s_awready, s_wvalid, s_wready;
    wire [1:0]  s_bresp, s_rresp;
    wire        s_bvalid, s_bready, s_arvalid, s_arready, s_rvalid, s_rready;

    jtag_axi_0 u_jtag_axi (
        .aclk          (sys_clk),
        .aresetn       (rst_n),
        .m_axi_awaddr  (s_awaddr),
        .m_axi_awvalid (s_awvalid),
        .m_axi_awready (s_awready),
        .m_axi_awprot  (),
        .m_axi_wdata   (s_wdata),
        .m_axi_wstrb   (s_wstrb),
        .m_axi_wvalid  (s_wvalid),
        .m_axi_wready  (s_wready),
        .m_axi_bresp   (s_bresp),
        .m_axi_bvalid  (s_bvalid),
        .m_axi_bready  (s_bready),
        .m_axi_araddr  (s_araddr),
        .m_axi_arvalid (s_arvalid),
        .m_axi_arready (s_arready),
        .m_axi_arprot  (),
        .m_axi_rdata   (s_rdata),
        .m_axi_rresp   (s_rresp),
        .m_axi_rvalid  (s_rvalid),
        .m_axi_rready  (s_rready)
    );

    axil_loader_bridge u_axil_bridge (
        .clk (sys_clk), .rst_n (rst_n),
        .s_axi_awaddr(s_awaddr), .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
        .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
        .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
        .s_axi_araddr(s_araddr), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
        .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),
        .s_axis_tdata(a_tx_data), .s_axis_tvalid(a_tx_valid), .s_axis_tready(a_tx_ready),
        .m_axis_tdata(a_rx_data), .m_axis_tvalid(a_rx_valid), .m_axis_tready(a_rx_ready),
        .weights_ready(weights_ready), .act_valid(act_valid),
        .busy(busy), .err_code(err_code)
    );
`else
    // No JTAG-AXI in this build: park the port so the mux below is unconditional.
    assign a_tx_data  = 8'd0;
    assign a_tx_valid = 1'b0;
    assign a_rx_ready = 1'b0;
`endif

    // ------------------------------------------------------------------
    // Byte-stream arbitration
    // ------------------------------------------------------------------
    // AXI wins ties: a JTAG transaction is already committed by the time it
    // reaches us, whereas a UART byte can be held indefinitely by its own
    // handshake.
    wire        ld_valid;
    wire [7:0]  ld_data;
    wire        ld_ready;

    assign ld_valid = a_tx_valid | u_rx_valid;
    assign ld_data  = a_tx_valid ? a_tx_data : u_rx_data;

    assign a_tx_ready = ld_ready && a_tx_valid;
    assign u_rx_ready = ld_ready && !a_tx_valid;

    // Replies go back to whoever spoke last, so a UART host and a JTAG host can
    // both interrogate the same board without stealing each other's data.
    reg reply_to_axi;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) reply_to_axi <= 1'b0;
        else if (ld_valid && ld_ready) reply_to_axi <= a_tx_valid;
    end

    wire        ld_mvalid;
    wire [7:0]  ld_mdata;
    wire        ld_mready;

    assign ld_mready = reply_to_axi ? a_rx_ready : u_tx_ready;
    assign a_rx_valid = ld_mvalid &  reply_to_axi;
    assign a_rx_data  = ld_mdata;
    assign u_tx_valid = ld_mvalid & ~reply_to_axi;
    assign u_tx_data  = ld_mdata;

    // ------------------------------------------------------------------
    // Loader
    // ------------------------------------------------------------------
    wire                       w_wr_en;
    wire [1:0]                 w_wr_region;
    wire [`H_ADDR_W-1:0]       w_wr_addr;
    wire [`REGION_WCODE_W-1:0] w_wr_data;

    wire                       a_wr_en;
    wire [`H_ADDR_W-1:0]       a_wr_addr;
    wire [`ACT_W-1:0]          a_wr_data;

    wire        gemv_start, gemv_busy, gemv_done;
    wire        rd_start;
    wire [`E_ADDR_W-1:0] rd_start_lane;
    wire        rd_pause, rd_valid, rd_busy;
    wire [`E_ADDR_W-1:0] rd_lane;
    wire [1:0]  rd_byte;
    wire [7:0]  rd_data;

    // Weight readback: narrow only.  The 256-bit row is selected and serialised
    // inside gemv_engine so it never has to cross the die to reach the loader.
    wire                    rb_start;
    wire [1:0]              rb_region;
    wire [`H_ADDR_W-1:0]    rb_addr;
    wire [15:0]             rb_nrows;
    wire                    rb_byte_ready;
    wire [7:0]              rb_byte_out;
    wire                    rb_byte_valid;
    wire                    rb_done;

    // weights_ready / act_valid / busy / err_code are declared above, next to the
    // AXI bridge that also consumes them.
    wire [31:0] result_checksum;

    moe_loader u_loader (
        .clk (sys_clk), .rst_n (rst_n),
        .s_axis_tdata (ld_data), .s_axis_tvalid (ld_valid),
        .s_axis_tready(ld_ready), .s_axis_tlast (1'b0),
        .m_axis_tdata (ld_mdata), .m_axis_tvalid(ld_mvalid),
        .m_axis_tready(ld_mready), .m_axis_tlast(),
        .w_wr_en(w_wr_en), .w_wr_region(w_wr_region),
        .w_wr_addr(w_wr_addr), .w_wr_data(w_wr_data),
        .a_wr_en(a_wr_en), .a_wr_addr(a_wr_addr), .a_wr_data(a_wr_data),
        .gemv_start(gemv_start), .gemv_busy(gemv_busy), .gemv_done(gemv_done),
        .rd_start(rd_start), .rd_start_lane(rd_start_lane), .rd_pause(rd_pause),
        .rd_valid(rd_valid), .rd_lane(rd_lane), .rd_byte(rd_byte),
        .rd_data(rd_data), .rd_busy(rd_busy),
        .rb_start(rb_start), .rb_region(rb_region), .rb_addr(rb_addr),
        .rb_nrows(rb_nrows), .rb_byte_ready(rb_byte_ready),
        .rb_byte_out(rb_byte_out), .rb_byte_valid(rb_byte_valid), .rb_done(rb_done),
        .weights_ready(weights_ready), .act_valid(act_valid),
        .busy(busy), .err_code(err_code)
    );

    // ------------------------------------------------------------------
    // Engine
    // ------------------------------------------------------------------
    moe_proto_top u_moe_proto_top (
        .clk            (sys_clk),
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
        .result_checksum(result_checksum)
    );

    // ------------------------------------------------------------------
    // Status LEDs, active LOW
    // ------------------------------------------------------------------
    //   LED1  lit when weights are loaded
    //   LED2  lit when the activation vector is loaded
    //   LED3  lit while a GEMV is running
    //   LED4  heartbeat: blinks while healthy, solid lit on a sticky error
    //
    // The heartbeat matters: without it a correctly configured idle board and an
    // unconfigured one both show all four LEDs dark, which is the same ambiguity
    // that made the earlier PASS/FAIL bring-up confusing.
    //
    // Deliberately not a PASS/FAIL verdict any more: with runtime-loadable weights
    // there is no single golden checksum, so the host is the judge and the LEDs
    // only report state.
    reg [24:0] blink_cnt;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) blink_cnt <= 25'd0;
        else        blink_cnt <= blink_cnt + 25'd1;
    end

    wire blink_phase = blink_cnt[BLINK_BIT];

    assign led[0] = ~weights_ready;
    assign led[1] = ~act_valid;
    assign led[2] = ~busy;
    assign led[3] = (err_code == 8'h00) ? blink_phase : 1'b0;

    wire unused_checksum = ^result_checksum;

endmodule
