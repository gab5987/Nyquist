// Simulation-only behavioral SDRAM model (4 banks x 8192 rows x 512 cols x 16).
// Sparse memory, CL 2/3, burst length 1, tAC/tOH on DQ, timing checks ($error).
`timescale 1ns/1ps
module sdram_model #(
  parameter int      ROW_WIDTH  = 13,
  parameter int      COL_WIDTH  = 9,
  parameter int      BANK_WIDTH = 2,
  parameter int      DATA_WIDTH = 16,
  parameter realtime T_AC       = 5.4ns,
  parameter realtime T_OH       = 2.7ns,
  parameter realtime T_RCD      = 20ns,
  parameter realtime T_RP       = 20ns,
  parameter realtime T_RAS      = 42ns,
  parameter realtime T_RC       = 63ns,
  parameter realtime T_INIT     = 200us,
  parameter realtime T_REFI_MAX = 7.8125us,
  parameter int      T_WR_CYC   = 2,
  parameter int      T_MRD_CYC  = 2
) (
  input  logic                    clk,
  input  logic                    cke,
  input  logic                    cs_n,
  input  logic                    ras_n,
  input  logic                    cas_n,
  input  logic                    we_n,
  input  logic [BANK_WIDTH-1:0]   ba,
  input  logic [ROW_WIDTH-1:0]    a,
  input  logic [DATA_WIDTH/8-1:0] dqm,
  inout  wire  [DATA_WIDTH-1:0]   dq
);

  localparam int NB         = 1 << BANK_WIDTH;
  localparam int ADDR_WIDTH = ROW_WIDTH + BANK_WIDTH + COL_WIDTH;

  typedef enum logic [3:0] {
    C_INHIBIT = 4'b1111, C_NOP = 4'b0111, C_ACTIVE = 4'b0011, C_READ = 4'b0101,
    C_WRITE = 4'b0100, C_PRECHARGE = 4'b0010, C_REFRESH = 4'b0001, C_MRS = 4'b0000
  } cmd_t;

  logic [DATA_WIDTH-1:0] mem [logic [ADDR_WIDTH-1:0]];

  logic                 bank_open [NB];
  logic [ROW_WIDTH-1:0] bank_row  [NB];
  realtime              t_act     [NB];
  realtime              t_pre     [NB];
  realtime              t_write   [NB];

  realtime t_power_up, t_last_edge, t_period, t_last_ref, t_mrs, t_last_act_any;
  int      cas_latency   = 3;
  bit      mode_loaded   = 0;
  bit      first_cmd     = 1;
  int      refresh_count = 0;
  int      violations    = 0;

  // Pending reads, one entry per latency stage
  logic [DATA_WIDTH-1:0] rd_data  [0:3];
  logic                  rd_valid [0:3];

  logic [DATA_WIDTH-1:0] dq_out;
  logic                  dq_oe;
  assign dq = dq_oe ? dq_out : {DATA_WIDTH{1'bz}};

  initial begin
    t_power_up = $realtime;
    t_last_ref = $realtime;
    t_last_edge = 0;
    t_period = 0;
    for (int i = 0; i < NB; i++) begin
      bank_open[i] = 0; t_act[i] = -1ms; t_pre[i] = -1ms; t_write[i] = -1ms;
    end
    for (int i = 0; i < 4; i++) rd_valid[i] = 0;
    dq_oe = 0;
  end

  function automatic cmd_t decode();
    return cmd_t'({cs_n, ras_n, cas_n, we_n});
  endfunction

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      violations++;
      $error("[sdram_model] %s @ %t", msg, $realtime);
    end
  endtask

  always @(posedge clk) begin
    cmd_t cmd;
    int   b;
    realtime now;

    now = $realtime;
    if (t_last_edge != 0) t_period = now - t_last_edge;
    t_last_edge = now;

    // Read issued at edge N drives DQ after edge N+CL-1 (+tAC)
    if (cas_latency >= 2 && rd_valid[cas_latency-2]) begin
      dq_out <= #(T_AC) rd_data[cas_latency-2];
      dq_oe  <= #(T_AC) 1'b1;
    end else begin
      dq_oe  <= #(T_OH) 1'b0;
    end
    for (int i = 3; i > 0; i--) begin
      rd_data[i]  <= rd_data[i-1];
      rd_valid[i] <= rd_valid[i-1];
    end
    rd_valid[0] <= 1'b0;

    if (cke) begin
      cmd = decode();
      b   = ba;

      if (cmd != C_NOP && cmd != C_INHIBIT && first_cmd) begin
        first_cmd = 0;
        check(now - t_power_up >= T_INIT,
              $sformatf("first command before init delay of %t", T_INIT));
        check(cmd == C_PRECHARGE && a[10], "first command must be PRECHARGE ALL");
      end

      case (cmd)
        C_ACTIVE: begin
          check(mode_loaded, "ACTIVE before LOAD MODE REGISTER");
          check(!bank_open[b], $sformatf("ACTIVE on open bank %0d", b));
          check(now - t_pre[b] >= T_RP,  $sformatf("tRP violated, bank %0d", b));
          check(now - t_act[b] >= T_RC,  $sformatf("tRC violated, bank %0d", b));
          check(now - t_last_ref >= T_RC, "tRC (REFRESH->ACTIVE) violated");
          check(now - t_mrs >= T_MRD_CYC * t_period, "tMRD violated");
          bank_open[b] = 1;
          bank_row[b]  = a;
          t_act[b]     = now;
          t_last_act_any = now;
        end

        C_READ, C_WRITE: begin
          logic [ADDR_WIDTH-1:0] full;
          check(bank_open[b], $sformatf("%s on closed bank %0d", cmd.name(), b));
          check(now - t_act[b] >= T_RCD, $sformatf("tRCD violated, bank %0d", b));
          check(!a[10], "auto-precharge not supported by model");
          full = {bank_row[b], ba, a[COL_WIDTH-1:0]};
          if (cmd == C_READ) begin
            rd_data[0]  <= mem.exists(full) ? mem[full] : {DATA_WIDTH{1'bx}};
            rd_valid[0] <= 1'b1;
          end else begin
            logic [DATA_WIDTH-1:0] cur;
            cur = mem.exists(full) ? mem[full] : {DATA_WIDTH{1'bx}};
            for (int i = 0; i < DATA_WIDTH/8; i++)
              if (!dqm[i]) cur[i*8 +: 8] = dq[i*8 +: 8];
            mem[full]  = cur;
            t_write[b] = now;
          end
        end

        C_PRECHARGE: begin
          for (int i = 0; i < NB; i++) begin
            if (a[10] || i == b) begin
              if (bank_open[i]) begin
                check(now - t_act[i]   >= T_RAS, $sformatf("tRAS violated, bank %0d", i));
                check(now - t_write[i] >= T_WR_CYC * t_period,
                      $sformatf("tWR violated, bank %0d", i));
              end
              bank_open[i] = 0;
              t_pre[i]     = now;
            end
          end
        end

        C_REFRESH: begin
          for (int i = 0; i < NB; i++)
            check(!bank_open[i], $sformatf("REFRESH with bank %0d open", i));
          for (int i = 0; i < NB; i++)
            check(now - t_pre[i] >= T_RP, "tRP (PRECHARGE->REFRESH) violated");
          check(now - t_last_ref >= T_RC, "tRC (REFRESH->REFRESH) violated");
          check(now - t_last_act_any >= T_RC, "tRC (ACTIVE->REFRESH) violated");
          if (mode_loaded)
            check(now - t_last_ref <= T_REFI_MAX,
                  $sformatf("refresh interval %t > %t", now - t_last_ref, T_REFI_MAX));
          t_last_ref = now;
          refresh_count++;
        end

        C_MRS: begin
          for (int i = 0; i < NB; i++)
            check(!bank_open[i], "LOAD MODE with open bank");
          check(a[2:0] == 3'b000, "model supports burst length 1 only");
          cas_latency = a[6:4];
          check(cas_latency == 2 || cas_latency == 3, "invalid CAS latency");
          mode_loaded = 1;
          t_mrs = now;
          $display("[sdram_model] LOAD MODE: CL=%0d BL=1 @ %t", cas_latency, now);
        end

        default: ;
      endcase
    end
  end

endmodule
