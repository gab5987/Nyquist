// DE0-Nano top: PLL + sdram_ctrl + sdram_tester (full 32 MB memory test).
// LED[0] init_done, LED[1] busy, LED[2] pass, LED[3] fail,
// LED[6:4] progress, LED[7] heartbeat. KEY[0] reset, KEY[1] restart test.
// USE_ISSP adds an In-System Sources and Probes instance "STAT" for JTAG
// status readout (scripts/status.tcl).
module de0_nano_top #(
  parameter bit USE_ISSP   = 1'b1,
  parameter int TEST_WORDS = 1 << 24
) (
  input  logic        CLOCK_50,
  input  logic [1:0]  KEY,
  output logic [7:0]  LED,

  output logic [12:0] DRAM_ADDR,
  output logic [1:0]  DRAM_BA,
  output logic        DRAM_CAS_N,
  output logic        DRAM_CKE,
  output logic        DRAM_CLK,
  output logic        DRAM_CS_N,
  inout  wire  [15:0] DRAM_DQ,
  output logic [1:0]  DRAM_DQM,
  output logic        DRAM_RAS_N,
  output logic        DRAM_WE_N
);

  localparam int ADDR_WIDTH = 24;
  localparam int DATA_WIDTH = 16;

  // Clock / reset
  logic clk_sys, clk_sdram, pll_locked, rst_n;

  sdram_pll u_pll (
    .inclk     (CLOCK_50),
    .areset    (1'b0),
    .clk_sys   (clk_sys),
    .clk_sdram (clk_sdram),
    .locked    (pll_locked)
  );

  assign DRAM_CLK = clk_sdram;

  reset_sync u_rst (
    .clk    (clk_sys),
    .arst_n (pll_locked & KEY[0]),
    .rst_n  (rst_n)
  );

  // SDRAM controller
  logic                    m_req, m_we, m_ack, m_rvalid, m_ready, init_done;
  logic [ADDR_WIDTH-1:0]   m_addr;
  logic [DATA_WIDTH-1:0]   m_wdata, m_rdata;
  logic [DATA_WIDTH/8-1:0] m_be;

  sdram_ctrl #(
    .CLK_FREQ_HZ (100_000_000),
    .CAS_LATENCY (3)
  ) u_sdram (
    .clk         (clk_sys),
    .rst_n       (rst_n),
    .req         (m_req),
    .we          (m_we),
    .addr        (m_addr),
    .wdata       (m_wdata),
    .be          (m_be),
    .ack         (m_ack),
    .rdata       (m_rdata),
    .rvalid      (m_rvalid),
    .ready       (m_ready),
    .init_done   (init_done),
    .sdram_cke   (DRAM_CKE),
    .sdram_cs_n  (DRAM_CS_N),
    .sdram_ras_n (DRAM_RAS_N),
    .sdram_cas_n (DRAM_CAS_N),
    .sdram_we_n  (DRAM_WE_N),
    .sdram_ba    (DRAM_BA),
    .sdram_a     (DRAM_ADDR),
    .sdram_dqm   (DRAM_DQM),
    .sdram_dq    (DRAM_DQ)
  );

  // Test start: once after reset, KEY[1] press, or ISSP source
  logic [2:0] key1_s;
  logic       start_after_reset;
  logic       issp_start;

  always_ff @(posedge clk_sys) begin
    if (!rst_n) begin
      key1_s            <= '1;
      start_after_reset <= 1'b1;
    end else begin
      key1_s            <= {key1_s[1:0], KEY[1]};
      start_after_reset <= 1'b0;
    end
  end

  wire key1_fall = key1_s[2] & ~key1_s[1];
  wire t_start   = start_after_reset | key1_fall | issp_start;

  // Memory test
  logic                  t_busy, t_done, t_pass, t_fail;
  logic [1:0]            t_phase;
  logic [ADDR_WIDTH-1:0] t_cur_addr, t_first_err_addr;
  logic [15:0]           t_err_cnt;

  sdram_tester #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .TEST_WORDS (TEST_WORDS)
  ) u_test (
    .clk            (clk_sys),
    .rst_n          (rst_n),
    .start          (t_start),
    .req            (m_req),
    .we             (m_we),
    .addr           (m_addr),
    .wdata          (m_wdata),
    .be             (m_be),
    .ack            (m_ack),
    .rdata          (m_rdata),
    .rvalid         (m_rvalid),
    .busy           (t_busy),
    .done           (t_done),
    .pass           (t_pass),
    .fail           (t_fail),
    .phase          (t_phase),
    .cur_addr       (t_cur_addr),
    .first_err_addr (t_first_err_addr),
    .err_cnt        (t_err_cnt)
  );

  // LEDs
  logic [26:0] heartbeat;
  always_ff @(posedge clk_sys) heartbeat <= heartbeat + 1'b1;

  assign LED[0]   = init_done;
  assign LED[1]   = t_busy;
  assign LED[2]   = t_pass;
  assign LED[3]   = t_fail;
  assign LED[6:4] = t_cur_addr[ADDR_WIDTH-1 -: 3];
  assign LED[7]   = heartbeat[26];

  // ISSP: probe[0]=init_done [1]=busy [2]=done [3]=pass [4]=fail [9:8]=phase
  // [31:16]=err_cnt [55:32]=first_err_addr [63:56]=cur_addr[23:16]
  // source[0] rising edge restarts the test
  generate
    if (USE_ISSP) begin : g_issp
      logic [63:0] probe;
      logic [0:0]  source;
      logic [2:0]  src_s;

      assign probe = { t_cur_addr[ADDR_WIDTH-1 -: 8], t_first_err_addr, t_err_cnt,
                       6'b0, t_phase, 3'b0, t_fail, t_pass, t_done, t_busy, init_done };

      always_ff @(posedge clk_sys) src_s <= {src_s[1:0], source[0]};
      assign issp_start = src_s[1] & ~src_s[2];

      altsource_probe #(
        .enable_metastability    ("NO"),
        .instance_id             ("STAT"),
        .probe_width             (64),
        .sld_auto_instance_index ("YES"),
        .sld_instance_index      (0),
        .source_initial_value    ("0"),
        .source_width            (1),
        .lpm_type                ("altsource_probe")
      ) u_issp (
        .probe      (probe),
        .source     (source),
        .source_clk (1'b0),
        .source_ena (1'b1)
      );
    end else begin : g_no_issp
      assign issp_start = 1'b0;
    end
  endgenerate

endmodule
