// Testbench: sdram_ctrl + sdram_tester + sdram_model with board delays
// (SDRAM clock = clk shifted by SDRAM_PHASE + T_CO, outputs delayed T_CO,
// DQ input delayed T_IN). Runs the memory test, then byte-enable checks.
`timescale 1ns/1ps
module tb_sdram;

  parameter realtime CLK_PERIOD  = 10ns;
  parameter realtime SDRAM_PHASE = 7ns;     // -3 ns phase shift
  parameter realtime T_CO        = 4ns;
  parameter realtime T_IN        = 1.5ns;
  parameter int      TEST_WORDS  = 4096;    // 512 cols x 4 banks x 2 rows
  parameter int      CAS_LATENCY = 3;

  localparam int AW = 24;
  localparam int DW = 16;

  logic clk = 1'b0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  logic rst_n = 1'b0;

  // User bus: tester or TB (tb_owns_bus)
  logic          tb_owns_bus = 1'b0;

  logic          t_req, t_we;
  logic [AW-1:0] t_addr;
  logic [DW-1:0] t_wdata;
  logic [1:0]    t_be;

  logic          d_req = 0, d_we = 0;
  logic [AW-1:0] d_addr = '0;
  logic [DW-1:0] d_wdata = '0;
  logic [1:0]    d_be = '1;

  logic          m_req, m_we, m_ack, m_rvalid, m_ready, init_done;
  logic [AW-1:0] m_addr;
  logic [DW-1:0] m_wdata, m_rdata;
  logic [1:0]    m_be;

  assign m_req   = tb_owns_bus ? d_req   : t_req;
  assign m_we    = tb_owns_bus ? d_we    : t_we;
  assign m_addr  = tb_owns_bus ? d_addr  : t_addr;
  assign m_wdata = tb_owns_bus ? d_wdata : t_wdata;
  assign m_be    = tb_owns_bus ? d_be    : t_be;

  // FPGA-side pins
  logic        cke, cs_n, ras_n, cas_n, we_n;
  logic [1:0]  ba, dqm;
  logic [12:0] a;
  wire  [15:0] ctrl_dq;

  sdram_ctrl #(
    .CLK_FREQ_HZ (100_000_000),
    .CAS_LATENCY (CAS_LATENCY)
  ) u_ctrl (
    .clk         (clk),
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
    .sdram_cke   (cke),
    .sdram_cs_n  (cs_n),
    .sdram_ras_n (ras_n),
    .sdram_cas_n (cas_n),
    .sdram_we_n  (we_n),
    .sdram_ba    (ba),
    .sdram_a     (a),
    .sdram_dqm   (dqm),
    .sdram_dq    (ctrl_dq)
  );

  logic          t_start = 1'b0;
  logic          t_busy, t_done, t_pass, t_fail;
  logic [1:0]    t_phase;
  logic [AW-1:0] t_cur_addr, t_first_err_addr;
  logic [15:0]   t_err_cnt;

  sdram_tester #(
    .ADDR_WIDTH (AW),
    .DATA_WIDTH (DW),
    .TEST_WORDS (TEST_WORDS)
  ) u_test (
    .clk            (clk),
    .rst_n          (rst_n),
    .start          (t_start),
    .req            (t_req),
    .we             (t_we),
    .addr           (t_addr),
    .wdata          (t_wdata),
    .be             (t_be),
    .ack            (m_ack & ~tb_owns_bus),
    .rdata          (m_rdata),
    .rvalid         (m_rvalid & ~tb_owns_bus),
    .busy           (t_busy),
    .done           (t_done),
    .pass           (t_pass),
    .fail           (t_fail),
    .phase          (t_phase),
    .cur_addr       (t_cur_addr),
    .first_err_addr (t_first_err_addr),
    .err_cnt        (t_err_cnt)
  );

  // Board delays
  logic        s_clk;
  logic        s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
  logic [1:0]  s_ba, s_dqm;
  logic [12:0] s_a;
  wire  [15:0] s_dq;

  always @(clk) s_clk <= #(SDRAM_PHASE + T_CO) clk;

  assign #(T_CO) s_cke   = cke;
  assign #(T_CO) s_cs_n  = cs_n;
  assign #(T_CO) s_ras_n = ras_n;
  assign #(T_CO) s_cas_n = cas_n;
  assign #(T_CO) s_we_n  = we_n;
  assign #(T_CO) s_ba    = ba;
  assign #(T_CO) s_a     = a;
  assign #(T_CO) s_dqm   = dqm;

  // DQ FPGA -> SDRAM
  logic        f_oe;
  logic [15:0] f_dq;
  assign #(T_CO) f_oe = u_ctrl.dq_oe_r;
  assign #(T_CO) f_dq = u_ctrl.dq_out_r;
  assign s_dq = f_oe ? f_dq : 16'bz;

  // DQ SDRAM -> FPGA
  logic [15:0] s_dq_in;
  assign #(T_IN) s_dq_in = s_dq;
  assign ctrl_dq = u_ctrl.dq_oe_r ? 16'bz : s_dq_in;

  sdram_model u_model (
    .clk   (s_clk),
    .cke   (s_cke),
    .cs_n  (s_cs_n),
    .ras_n (s_ras_n),
    .cas_n (s_cas_n),
    .we_n  (s_we_n),
    .ba    (s_ba),
    .a     (s_a),
    .dqm   (s_dqm),
    .dq    (s_dq)
  );

  task automatic tb_write(input logic [AW-1:0] addr, input logic [DW-1:0] data,
                          input logic [1:0] be);
    @(posedge clk);
    d_req <= 1; d_we <= 1; d_addr <= addr; d_wdata <= data; d_be <= be;
    do @(posedge clk); while (!m_ack);
    d_req <= 0;
  endtask

  task automatic tb_read(input logic [AW-1:0] addr, output logic [DW-1:0] data);
    @(posedge clk);
    d_req <= 1; d_we <= 0; d_addr <= addr;
    do @(posedge clk); while (!m_ack);
    d_req <= 0;
    do @(posedge clk); while (!m_rvalid);
    data = m_rdata;
  endtask

  int      tb_errors = 0;
  realtime t_init;
  logic [DW-1:0] rd;

  initial begin
    $display("=== tb_sdram: CL=%0d, TEST_WORDS=%0d ===", CAS_LATENCY, TEST_WORDS);
    repeat (5) @(posedge clk);
    rst_n <= 1'b1;

    @(posedge init_done);
    t_init = $realtime;
    $display("[tb] SDRAM initialized at %t", t_init);

    @(posedge clk); t_start <= 1'b1;
    @(posedge clk); t_start <= 1'b0;
    @(posedge t_done);
    $display("[tb] sdram_tester: pass=%0d fail=%0d err_cnt=%0d first_err_addr=0x%06X (%t)",
             t_pass, t_fail, t_err_cnt, t_first_err_addr, $realtime);
    if (!t_pass) tb_errors++;

    // Byte enable
    repeat (4) @(posedge clk);
    tb_owns_bus <= 1'b1;
    tb_write(24'h12345A, 16'h1234, 2'b11);
    tb_write(24'h12345A, 16'hBEEF, 2'b01);
    tb_read (24'h12345A, rd);
    if (rd !== 16'h12EF) begin
      $error("[tb] low byte enable: expected 0x12EF, got 0x%04X", rd);
      tb_errors++;
    end
    tb_write(24'h12345A, 16'hCAFE, 2'b10);
    tb_read (24'h12345A, rd);
    if (rd !== 16'hCAEF) begin
      $error("[tb] high byte enable: expected 0xCAEF, got 0x%04X", rd);
      tb_errors++;
    end
    // Address extremes
    tb_write(24'h000000, 16'h0001, 2'b11);
    tb_write(24'hFFFFFF, 16'h8000, 2'b11);
    tb_read (24'h000000, rd); if (rd !== 16'h0001) begin $error("[tb] addr 0"); tb_errors++; end
    tb_read (24'hFFFFFF, rd); if (rd !== 16'h8000) begin $error("[tb] addr max"); tb_errors++; end

    repeat (20) @(posedge clk);

    $display("[tb] refreshes: %0d, model timing violations: %0d",
             u_model.refresh_count, u_model.violations);
    if (u_model.violations != 0) tb_errors++;

    if (tb_errors == 0) $display("=== RESULT: PASS ===");
    else                $display("=== RESULT: FAIL (%0d error(s)) ===", tb_errors);
    $finish;
  end

  initial begin
    #20ms;
    $error("[tb] timeout");
    $finish;
  end

endmodule
