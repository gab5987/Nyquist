// Memory test, example user of sdram_ctrl.
// On start: write pattern(addr) to all words, read back and compare;
// then repeat with the inverted pattern.
module sdram_tester #(
  parameter int ADDR_WIDTH = 24,
  parameter int DATA_WIDTH = 16,
  parameter int TEST_WORDS = 1 << 24
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    start,

  // sdram_ctrl
  output logic                    req,
  output logic                    we,
  output logic [ADDR_WIDTH-1:0]   addr,
  output logic [DATA_WIDTH-1:0]   wdata,
  output logic [DATA_WIDTH/8-1:0] be,
  input  logic                    ack,
  input  logic [DATA_WIDTH-1:0]   rdata,
  input  logic                    rvalid,

  // Status
  output logic                    busy,
  output logic                    done,
  output logic                    pass,
  output logic                    fail,
  output logic [1:0]              phase,          // {inverted pass, reading}
  output logic [ADDR_WIDTH-1:0]   cur_addr,
  output logic [ADDR_WIDTH-1:0]   first_err_addr,
  output logic [15:0]             err_cnt
);

  localparam logic [ADDR_WIDTH-1:0] LAST = ADDR_WIDTH'(TEST_WORDS - 1);

  typedef enum logic [1:0] {T_IDLE, T_WRITE, T_READ, T_DONE} tstate_t;
  tstate_t state;

  logic                  inv;
  logic [ADDR_WIDTH-1:0] idx;
  logic [ADDR_WIDTH-1:0] pend_addr;    // address of the outstanding read
  logic                  last_issued;

  function automatic logic [DATA_WIDTH-1:0] pattern(
      input logic [ADDR_WIDTH-1:0] a, input logic invert);
    logic [DATA_WIDTH-1:0] p;
    p = DATA_WIDTH'(a) ^ DATA_WIDTH'(a >> (DATA_WIDTH - 8)) ^ DATA_WIDTH'('hA5C3);
    return invert ? ~p : p;
  endfunction

  assign req      = (state == T_WRITE) || (state == T_READ && !last_issued);
  assign we       = (state == T_WRITE);
  assign addr     = idx;
  assign wdata    = pattern(idx, inv);
  assign be       = '1;

  assign busy     = (state == T_WRITE) || (state == T_READ);
  assign done     = (state == T_DONE);
  assign pass     = done && (err_cnt == 0);
  assign fail     = done && (err_cnt != 0);
  assign phase    = {inv, state == T_READ};
  assign cur_addr = idx;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state          <= T_IDLE;
      inv            <= 1'b0;
      idx            <= '0;
      pend_addr      <= '0;
      last_issued    <= 1'b0;
      err_cnt        <= '0;
      first_err_addr <= '0;
    end else begin
      case (state)
        T_IDLE, T_DONE: begin
          if (start) begin
            state          <= T_WRITE;
            inv            <= 1'b0;
            idx            <= '0;
            last_issued    <= 1'b0;
            err_cnt        <= '0;
            first_err_addr <= '0;
          end
        end

        T_WRITE: begin
          if (ack) begin
            if (idx == LAST) begin
              idx         <= '0;
              last_issued <= 1'b0;
              state       <= T_READ;
            end else begin
              idx <= idx + 1'b1;
            end
          end
        end

        T_READ: begin
          if (ack) begin
            pend_addr <= idx;
            if (idx == LAST) last_issued <= 1'b1;
            else             idx         <= idx + 1'b1;
          end
          if (rvalid) begin
            if (rdata != pattern(pend_addr, inv)) begin
              if (err_cnt == 0)  first_err_addr <= pend_addr;
              if (err_cnt != '1) err_cnt        <= err_cnt + 1'b1;
            end
            if (last_issued) begin
              if (inv) begin
                state <= T_DONE;
              end else begin
                inv   <= 1'b1;
                idx   <= '0;
                state <= T_WRITE;
              end
            end
          end
        end

        default: state <= T_IDLE;
      endcase
    end
  end

endmodule
