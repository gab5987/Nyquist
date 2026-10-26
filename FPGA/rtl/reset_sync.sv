// Reset synchronizer: async assert, sync release.
module reset_sync #(
  parameter int STAGES = 3
) (
  input  logic clk,
  input  logic arst_n,
  output logic rst_n
);

  logic [STAGES-1:0] sync;

  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) sync <= '0;
    else         sync <= {sync[STAGES-2:0], 1'b1};
  end

  assign rst_n = sync[STAGES-1];

endmodule
