
module util_gmii_to_rgmii (
  sys_clk,
  rst_n,
  reset,
  rgmii_td,
  rgmii_tx_ctl,
  rgmii_txc,
  rgmii_rd,
  rgmii_rx_ctl,
  gmii_rx_clk,
  rgmii_rxc,
  gmii_txd,
  gmii_tx_en,
  gmii_tx_er,
  gmii_tx_clk,
  gmii_crs,
  gmii_col,
  gmii_rxd,
  gmii_rx_dv,
  gmii_rx_er,
  speed_selection,
  idly_tap,
  idly_ld,
  idly_tap_out,
  duplex_mode
  );
  input           rst_n;
  input           sys_clk;
  input           rgmii_rxc;//add
  input           reset;
  output  [ 3:0]  rgmii_td;
  output          rgmii_tx_ctl;
  output          rgmii_txc;
  input   [ 3:0]  rgmii_rd;
  input           rgmii_rx_ctl;
  output           gmii_rx_clk;
(* MARK_DEBUG="true" *)  input   [ 7:0]  gmii_txd;
(* MARK_DEBUG="true" *)  input           gmii_tx_en;
  input           gmii_tx_er;
  output          gmii_tx_clk;
  output          gmii_crs;
  output          gmii_col;
   (* MARK_DEBUG="true" *)  output  [ 7:0]  gmii_rxd;
    (* MARK_DEBUG="true" *) output          gmii_rx_dv;
  output          gmii_rx_er;
  input  [ 1:0]   speed_selection; // 1x gigabit, 01 100Mbps, 00 10mbps

    // Runtime RX sampling-point control, added for bring-up.
    //
    // The AX7103B datasheet default-configuration table shows RXD0_RXDLY
    // strapped on, so this PHY already delays its receive clock by 2 ns - the
    // centre of the 4 ns RGMII bit window.  The fixed IDELAY_VALUE(10) this
    // module shipped with was tuned for a different PHY whose receive delay
    // defaults off, so here it adds about 0.78 ns that should not be there.
    //
    // Making the tap runtime-loadable turns "which value is right" from a
    // guess into a measurement: sweep 0..31 over JTAG and watch rec_error.
    input      [ 4:0]   idly_tap;       // 0..31 delay taps
    input               idly_ld;
    output     [ 4:0]   idly_tap_out;   // CNTVALUEOUT, proves the tap loaded
  input           duplex_mode;     // 1 full, 0 half
  
  wire gigabit;
  wire gmii_tx_clk_s;
  wire gmii_rx_dv_s;
  wire rdy;
  reg  rdy0;
  wire rgmii_rx_ctl_dl;
  wire[3:0] rgmii_rd_dl;
  wire  [ 7:0]    gmii_rxd_s;
  wire            rgmii_rx_ctl_delay;
  wire            rgmii_rx_ctl_s;
  // registers
  reg             tx_reset_d1;
  reg             tx_reset_sync;
  reg             rx_reset_d1;
  reg   [ 7:0]    gmii_txd_r;
  reg             gmii_tx_en_r;
  reg             gmii_tx_er_r;
  reg   [ 7:0]    gmii_txd_r_d1;
  reg             gmii_tx_en_r_d1;
  reg             gmii_tx_er_r_d1;

  reg             rgmii_tx_ctl_r;
  reg   [ 3:0]    gmii_txd_low;
  reg             gmii_col;
  reg             gmii_crs;

  reg  [ 7:0]     gmii_rxd;
  reg             gmii_rx_dv;
  reg             gmii_rx_er;

  assign gigabit        = speed_selection [1];
  assign gmii_tx_clk    = gmii_tx_clk_s;
  assign gmii_tx_clk_s  = gmii_rx_clk;
  BUFG bufmr_rgmii_rxc(
    .I(rgmii_rxc),
    .O(gmii_rx_clk)
   );

  always @(posedge gmii_rx_clk)
  begin
    gmii_rxd       = gmii_rxd_s;
    gmii_rx_dv     = gmii_rx_dv_s;
    gmii_rx_er     = gmii_rx_dv_s ^ rgmii_rx_ctl_s;
  end

  always @(posedge gmii_tx_clk_s) begin
    tx_reset_d1    <= reset;
    tx_reset_sync  <= tx_reset_d1;
  end

  always @(posedge gmii_tx_clk_s)
  begin
    rgmii_tx_ctl_r = gmii_tx_en_r ^ gmii_tx_er_r;
    gmii_txd_low   = gigabit ? gmii_txd_r[7:4] :  gmii_txd_r[3:0];
    gmii_col       = duplex_mode ? 1'b0 : (gmii_tx_en_r| gmii_tx_er_r) & ( gmii_rx_dv | gmii_rx_er) ;
    gmii_crs       = duplex_mode ? 1'b0 : (gmii_tx_en_r| gmii_tx_er_r| gmii_rx_dv | gmii_rx_er);
  end

  always @(posedge gmii_tx_clk_s) begin
    if (tx_reset_sync == 1'b1) begin
      gmii_txd_r   <= 8'h0;
      gmii_tx_en_r <= 1'b0;
      gmii_tx_er_r <= 1'b0;
    end
    else
    begin
      gmii_txd_r   <= gmii_txd;
      gmii_tx_en_r <= gmii_tx_en;
      gmii_tx_er_r <= gmii_tx_er;
      gmii_txd_r_d1   <= gmii_txd_r;
      gmii_tx_en_r_d1 <= gmii_tx_en_r;
      gmii_tx_er_r_d1 <= gmii_tx_er_r;
    end
  end
  


  ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE")
  ) rgmii_txc_out (
    .Q (rgmii_txc),
    .C (gmii_tx_clk_s),
    .CE(1),
    .D1(1),
    .D2(0),
    .R(tx_reset_sync),
    .S(0));


  generate
  genvar i;
  for (i = 0; i < 4; i = i + 1) begin : gen_tx_data
    ODDR #(
      .DDR_CLK_EDGE("SAME_EDGE")
    ) rgmii_td_out (
      .Q (rgmii_td[i]),
      .C (gmii_tx_clk_s),
      .CE(1),
      .D1(gmii_txd_r_d1[i]),
      .D2(gmii_txd_low[i]),
      .R(tx_reset_sync),
      .S(0));
  end
  


  endgenerate

  ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE")
  ) rgmii_tx_ctl_out (
    .Q (rgmii_tx_ctl),
    .C (gmii_tx_clk_s),
    .CE(1),
    .D1(gmii_tx_en_r_d1),
    .D2(rgmii_tx_ctl_r),
    .R(tx_reset_sync),
    .S(0));
    
 

   IDELAYCTRL IDELAYCTRL_rd (
      .RDY(),       // 1-bit output: Ready output
      .REFCLK(sys_clk), // 1-bit input: Reference clock input
      .RST(~rst_n)        // 1-bit input: Active high reset input
   );

   generate
      for (i = 0; i < 4; i = i + 1) begin
   IDELAYE2 #(
      .CINVCTRL_SEL("FALSE"),          // Enable dynamic clock inversion (FALSE, TRUE)
      .DELAY_SRC("IDATAIN"),           // Delay input (IDATAIN, DATAIN)
      .HIGH_PERFORMANCE_MODE("FALSE"), // Reduced jitter ("TRUE"), Reduced power ("FALSE")
      .IDELAY_TYPE("VAR_LOAD"),           // FIXED, VARIABLE, VAR_LOAD, VAR_LOAD_PIPE
      .IDELAY_VALUE(31),               // measured: 31 is the only value that works on
                                  // this board; the vendor's 10 was tuned for a
                                  // different PHY.  31 is the maximum tap.                // Input delay tap setting (0-31)
      .PIPE_SEL("FALSE"),              // Select pipelined mode, FALSE, TRUE
      .REFCLK_FREQUENCY(200.0),        // IDELAYCTRL clock input frequency in MHz (190.0-210.0, 290.0-310.0).
      .SIGNAL_PATTERN("DATA")          // DATA, CLOCK input signal
   )

   IDELAYE2_data (
      .CNTVALUEOUT(), // 5-bit output: Counter value output
      .DATAOUT(rgmii_rd_dl[i]),         // 1-bit output: Delayed data output
      .C(gmii_rx_clk),                     // 1-bit input: Clock input
      .CE(0),                   // 1-bit input: Active high enable increment/decrement input
      .CINVCTRL(0),       // 1-bit input: Dynamic clock inversion input
      .CNTVALUEIN(idly_tap),   // 5-bit input: Counter value input
      .DATAIN(0),           // 1-bit input: Internal delay data input
      .IDATAIN(rgmii_rd[i]),         // 1-bit input: Data input from the I/O
      .INC(0),                 // 1-bit input: Increment / Decrement tap delay input
      .LD(idly_ld),             // 1-bit input: Load IDELAY_VALUE input
      .LDPIPEEN(0),       // 1-bit input: Enable PIPELINE register to load data input
      .REGRST(0)            // 1-bit input: Active-high reset tap-delay input
   );
      end
     
      endgenerate
   IDELAYE2 #(
      .CINVCTRL_SEL("FALSE"),          // Enable dynamic clock inversion (FALSE, TRUE)
      .DELAY_SRC("IDATAIN"),           // Delay input (IDATAIN, DATAIN)
      .HIGH_PERFORMANCE_MODE("FALSE"), // Reduced jitter ("TRUE"), Reduced power ("FALSE")
      .IDELAY_TYPE("VAR_LOAD"),           // FIXED, VARIABLE, VAR_LOAD, VAR_LOAD_PIPE
      .IDELAY_VALUE(31),               // measured: 31 is the only value that works on
                                  // this board; the vendor's 10 was tuned for a
                                  // different PHY.  31 is the maximum tap.                // Input delay tap setting (0-31)
      .PIPE_SEL("FALSE"),              // Select pipelined mode, FALSE, TRUE
      .REFCLK_FREQUENCY(200.0),        // IDELAYCTRL clock input frequency in MHz (190.0-210.0, 290.0-310.0).
      .SIGNAL_PATTERN("DATA")          // DATA, CLOCK input signal
   )
   IDELAYE2_ctl (
      .CNTVALUEOUT(idly_tap_out), // 5-bit output: Counter value output
      .DATAOUT(rgmii_rx_ctl_dl),         // 1-bit output: Delayed data output
      .C(gmii_rx_clk),                     // 1-bit input: Clock input
      .CE(0),                   // 1-bit input: Active high enable increment/decrement input
      .CINVCTRL(0),       // 1-bit input: Dynamic clock inversion input
      .CNTVALUEIN(idly_tap),   // 5-bit input: Counter value input
      .DATAIN(0),           // 1-bit input: Internal delay data input
      .IDATAIN(rgmii_rx_ctl),         // 1-bit input: Data input from the I/O
      .INC(0),                 // 1-bit input: Increment / Decrement tap delay input
      .LD(idly_ld),             // 1-bit input: Load IDELAY_VALUE input
      .LDPIPEEN(0),       // 1-bit input: Enable PIPELINE register to load data input
      .REGRST(0)            // 1-bit input: Active-high reset tap-delay input
   );
     
      generate
      for (i = 0; i < 4; i = i + 1) begin
        IDDR #(
          .DDR_CLK_EDGE("SAME_EDGE_PIPELINED")
        ) rgmii_rx_iddr (
          .Q1(gmii_rxd_s[i]),
          .Q2(gmii_rxd_s[i+4]),
          .C(gmii_rx_clk),
          .CE(1),
          .D(rgmii_rd_dl[i]),
          .R(0),
          .S(0));
      end
      

   
      endgenerate
    
      IDDR #(
        .DDR_CLK_EDGE("SAME_EDGE_PIPELINED")
      ) rgmii_rx_ctl_iddr (
        .Q1(gmii_rx_dv_s),
        .Q2(rgmii_rx_ctl_s),
        .C(gmii_rx_clk),
        .CE(1),
        .D(rgmii_rx_ctl_dl),
        .R(0),
        .S(0));
        
        
        
endmodule