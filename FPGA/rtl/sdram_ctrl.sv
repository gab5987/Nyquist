// SDRAM controller for IS42S16160G (DE0-Nano, 32 MB x 16 bit).
// Single-word accesses, closed page: ACTIVE -> READ/WRITE -> PRECHARGE.
// Handles init sequence and periodic auto-refresh.
//
// User interface: hold req/we/addr/wdata/be until ack (1-cycle pulse).
// Read data returns on rdata with rvalid, always before the next ack.
// addr = {row[12:0], bank[1:0], col[8:0]} (16-bit word address).
// be[0] -> DQ[7:0], be[1] -> DQ[15:8].
module sdram_ctrl #(
  parameter int CLK_FREQ_HZ      = 100_000_000,
  parameter int ROW_WIDTH        = 13,
  parameter int COL_WIDTH        = 9,
  parameter int BANK_WIDTH       = 2,
  parameter int DATA_WIDTH       = 16,
  parameter int CAS_LATENCY      = 3,         // 2 or 3
  // IS42S16160G-7 timings
  parameter int T_INIT_NS        = 200_000,
  parameter int T_RP_NS          = 20,
  parameter int T_RCD_NS         = 20,
  parameter int T_RAS_NS         = 42,
  parameter int T_RC_NS          = 63,
  parameter int T_REFI_NS        = 7_500,     // 64 ms / 8192 = 7812 ns, with margin
  parameter int T_WR_CYC         = 2,
  parameter int T_MRD_CYC        = 2,
  // Cycles from READ command to DQ sampling at the FPGA pin.
  // CAS_LATENCY + 1 works with SDRAM clock shifted -3 ns at 100 MHz.
  parameter int READ_CAPTURE_CYC = CAS_LATENCY + 1,
  parameter int ADDR_WIDTH       = ROW_WIDTH + BANK_WIDTH + COL_WIDTH,
  parameter int BE_WIDTH         = DATA_WIDTH / 8
) (
  input  logic                  clk,
  input  logic                  rst_n,        // synchronous, active low

  // User interface
  input  logic                  req,
  input  logic                  we,
  input  logic [ADDR_WIDTH-1:0] addr,
  input  logic [DATA_WIDTH-1:0] wdata,
  input  logic [BE_WIDTH-1:0]   be,
  output logic                  ack,
  output logic [DATA_WIDTH-1:0] rdata,
  output logic                  rvalid,
  output logic                  ready,
  output logic                  init_done,

  // SDRAM pins
  output logic                  sdram_cke,
  output logic                  sdram_cs_n,
  output logic                  sdram_ras_n,
  output logic                  sdram_cas_n,
  output logic                  sdram_we_n,
  output logic [BANK_WIDTH-1:0] sdram_ba,
  output logic [ROW_WIDTH-1:0]  sdram_a,
  output logic [BE_WIDTH-1:0]   sdram_dqm,
  inout  wire  [DATA_WIDTH-1:0] sdram_dq
);

  // ns -> cycles, rounded up, minimum 1
  localparam int CLK_PERIOD_PS = 1_000_000 / (CLK_FREQ_HZ / 1_000_000);

  function automatic int ns2cyc(input int ns);
    int c;
    c = (ns * 1000 + CLK_PERIOD_PS - 1) / CLK_PERIOD_PS;
    return (c < 1) ? 1 : c;
  endfunction

  localparam int T_INIT = ns2cyc(T_INIT_NS);
  localparam int T_RP   = ns2cyc(T_RP_NS);
  localparam int T_RCD  = ns2cyc(T_RCD_NS);
  localparam int T_RAS  = ns2cyc(T_RAS_NS);
  localparam int T_RC   = ns2cyc(T_RC_NS);
  localparam int T_REFI = ns2cyc(T_REFI_NS);
  localparam int T_WR   = (T_WR_CYC  < 1) ? 1 : T_WR_CYC;
  localparam int T_MRD  = (T_MRD_CYC < 1) ? 1 : T_MRD_CYC;
  localparam int RC     = READ_CAPTURE_CYC;

  localparam int TIMER_W = $clog2(T_INIT + 1);
  localparam int REF_W   = $clog2(T_REFI + 1);
  localparam int RAS_W   = $clog2(T_RC + 1);

  // Commands: {cs_n, ras_n, cas_n, we_n}
  localparam logic [3:0] CMD_INHIBIT   = 4'b1111;
  localparam logic [3:0] CMD_NOP       = 4'b0111;
  localparam logic [3:0] CMD_ACTIVE    = 4'b0011;
  localparam logic [3:0] CMD_READ      = 4'b0101;
  localparam logic [3:0] CMD_WRITE     = 4'b0100;
  localparam logic [3:0] CMD_PRECHARGE = 4'b0010;
  localparam logic [3:0] CMD_REFRESH   = 4'b0001;
  localparam logic [3:0] CMD_LOAD_MODE = 4'b0000;

  // Mode register: single write, CAS latency, sequential, burst length 1
  localparam logic [ROW_WIDTH-1:0] MODE_REG =
    { {(ROW_WIDTH-10){1'b0}}, 1'b1, 2'b00, 3'(CAS_LATENCY), 1'b0, 3'b000 };

  typedef enum logic [3:0] {
    S_INIT_WAIT, S_INIT_PRE, S_INIT_REF, S_INIT_MRS,
    S_IDLE, S_REFRESH, S_ACTIVE, S_WRITE, S_READ, S_PRECHARGE
  } state_t;

  state_t               state;
  logic [TIMER_W-1:0]   timer;
  logic [RAS_W-1:0]     ras_timer;
  logic [RAS_W-1:0]     rc_timer;
  logic [REF_W-1:0]     ref_timer;
  logic                 ref_pending;
  logic [3:0]           init_ref_cnt;
  logic [RC:0]          rd_pipe;

  // Latched request
  logic [COL_WIDTH-1:0]  col_q;
  logic [DATA_WIDTH-1:0] wdata_q;
  logic [BE_WIDTH-1:0]   be_q;
  logic                  we_q;

  // I/O registers
  logic [3:0]            cmd_r;
  logic                  cke_r;
  logic [BANK_WIDTH-1:0] ba_r;
  logic [ROW_WIDTH-1:0]  a_r;
  logic [BE_WIDTH-1:0]   dqm_r;
  logic [DATA_WIDTH-1:0] dq_out_r;
  logic                  dq_oe_r;
  logic [DATA_WIDTH-1:0] dq_in_r;

  assign {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} = cmd_r;
  assign sdram_cke = cke_r;
  assign sdram_ba  = ba_r;
  assign sdram_a   = a_r;
  assign sdram_dqm = dqm_r;
  assign sdram_dq  = dq_oe_r ? dq_out_r : {DATA_WIDTH{1'bz}};

  always_ff @(posedge clk) dq_in_r <= sdram_dq;

  wire [COL_WIDTH-1:0]  addr_col  = addr[COL_WIDTH-1:0];
  wire [BANK_WIDTH-1:0] addr_bank = addr[COL_WIDTH +: BANK_WIDTH];
  wire [ROW_WIDTH-1:0]  addr_row  = addr[COL_WIDTH+BANK_WIDTH +: ROW_WIDTH];

  assign ready = (state == S_IDLE) && !ref_pending && (rc_timer == 0);
  wire accept  = ready && req;

  // "timer <= N-1" => next command N cycles after this one
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= S_INIT_WAIT;
      timer        <= TIMER_W'(T_INIT);
      ras_timer    <= '0;
      rc_timer     <= '0;
      ref_timer    <= '0;
      ref_pending  <= 1'b0;
      init_ref_cnt <= '0;
      rd_pipe      <= '0;
      init_done    <= 1'b0;
      ack          <= 1'b0;
      rvalid       <= 1'b0;
      rdata        <= '0;
      cmd_r        <= CMD_INHIBIT;
      cke_r        <= 1'b0;
      ba_r         <= '0;
      a_r          <= '0;
      dqm_r        <= '1;
      dq_out_r     <= '0;
      dq_oe_r      <= 1'b0;
      col_q        <= '0;
      wdata_q      <= '0;
      be_q         <= '0;
      we_q         <= 1'b0;
    end else begin
      // Defaults
      cmd_r   <= CMD_NOP;
      a_r     <= '0;
      ack     <= 1'b0;
      rvalid  <= 1'b0;
      dq_oe_r <= 1'b0;
      if (timer     != 0) timer     <= timer - 1'b1;
      if (ras_timer != 0) ras_timer <= ras_timer - 1'b1;
      if (rc_timer  != 0) rc_timer  <= rc_timer - 1'b1;

      // Read capture
      rd_pipe <= {rd_pipe[RC-1:0], 1'b0};
      if (rd_pipe[RC]) begin
        rdata  <= dq_in_r;
        rvalid <= 1'b1;
      end

      // Refresh timer
      if (init_done) begin
        if (ref_timer == 0) begin
          ref_timer   <= REF_W'(T_REFI - 1);
          ref_pending <= 1'b1;
        end else begin
          ref_timer <= ref_timer - 1'b1;
        end
      end

      case (state)
        S_INIT_WAIT: begin
          cke_r <= 1'b1;
          if (timer == 0) begin
            cmd_r    <= CMD_PRECHARGE;
            a_r[10]  <= 1'b1;                 // all banks
            timer    <= TIMER_W'(T_RP - 1);
            state    <= S_INIT_PRE;
          end
        end

        S_INIT_PRE: begin
          if (timer == 0) begin
            cmd_r        <= CMD_REFRESH;
            timer        <= TIMER_W'(T_RC - 1);
            init_ref_cnt <= 4'd1;
            state        <= S_INIT_REF;
          end
        end

        S_INIT_REF: begin
          if (timer == 0) begin
            if (init_ref_cnt < 4'd8) begin
              cmd_r        <= CMD_REFRESH;
              timer        <= TIMER_W'(T_RC - 1);
              init_ref_cnt <= init_ref_cnt + 1'b1;
            end else begin
              cmd_r <= CMD_LOAD_MODE;
              ba_r  <= '0;
              a_r   <= MODE_REG;
              timer <= TIMER_W'(T_MRD - 1);
              state <= S_INIT_MRS;
            end
          end
        end

        S_INIT_MRS: begin
          if (timer == 0) begin
            init_done <= 1'b1;
            dqm_r     <= '0;
            ref_timer <= REF_W'(T_REFI - 1);
            state     <= S_IDLE;
          end
        end

        S_IDLE: begin
          if (ref_pending && rc_timer == 0) begin
            cmd_r       <= CMD_REFRESH;
            ref_pending <= 1'b0;
            timer       <= TIMER_W'(T_RC - 1);
            state       <= S_REFRESH;
          end else if (accept) begin
            cmd_r     <= CMD_ACTIVE;
            ba_r      <= addr_bank;
            a_r       <= addr_row;
            col_q     <= addr_col;
            wdata_q   <= wdata;
            be_q      <= be;
            we_q      <= we;
            ack       <= 1'b1;
            timer     <= TIMER_W'(T_RCD - 1);
            ras_timer <= RAS_W'(T_RAS - 1);
            rc_timer  <= RAS_W'(T_RC - 1);
            state     <= S_ACTIVE;
          end
        end

        S_REFRESH: begin
          if (timer == 0) state <= S_IDLE;
        end

        S_ACTIVE: begin
          if (timer == 0) begin
            a_r <= ROW_WIDTH'(col_q);          // A10 = 0, no auto-precharge
            if (we_q) begin
              cmd_r    <= CMD_WRITE;
              dq_out_r <= wdata_q;
              dq_oe_r  <= 1'b1;
              dqm_r    <= ~be_q;
              timer    <= TIMER_W'(T_WR - 1);
              state    <= S_WRITE;
            end else begin
              cmd_r      <= CMD_READ;
              rd_pipe[0] <= 1'b1;
              timer      <= TIMER_W'(RC);
              state      <= S_READ;
            end
          end
        end

        S_WRITE: begin
          dqm_r <= '0;
          if (timer == 0 && ras_timer == 0) begin
            cmd_r   <= CMD_PRECHARGE;
            a_r[10] <= 1'b1;
            timer   <= TIMER_W'(T_RP - 1);
            state   <= S_PRECHARGE;
          end
        end

        S_READ: begin
          if (timer == 0 && ras_timer == 0) begin
            cmd_r   <= CMD_PRECHARGE;
            a_r[10] <= 1'b1;
            timer   <= TIMER_W'(T_RP - 1);
            state   <= S_PRECHARGE;
          end
        end

        S_PRECHARGE: begin
          if (timer == 0) state <= S_IDLE;
        end

        default: state <= S_INIT_WAIT;
      endcase
    end
  end

endmodule
