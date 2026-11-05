// sram_1r1w — §00-E leaf, weight-stationary tile SRAM bank.
// Behavior: synchronous write (we samples wa/wdata at posedge clk),
// synchronous 1-cycle read (ra sampled at posedge, rdata valid after that
// edge), write-first bypass (we && wa==ra forwards wdata to rdata).
// Out-of-range addresses (possible when N is not a power of 2) read as zero
// and writes to them are dropped. INIT_FILE optionally preloads the bank
// with a $readmemh hex image (one W-bit word per line); "" keeps zeros.
// Ports and W/N parameters are unchanged from the skeleton contract.
// LibreLane blackbox: under __librelane__ (defined by its synth/header
// steps only) this module keeps ports but elaborates no body — the macro
// is provided/etched, never mapped to logic. Sim flows never define it.
`ifdef __librelane__
(* blackbox *)
`endif
module sram_1r1w #(
  parameter W = 8,
  parameter N = 1024,
  parameter INIT_FILE = ""
)(
  input  wire         clk,
  input  wire [$clog2(N)-1:0] ra,
  input  wire [$clog2(N)-1:0] wa,
  input  wire [W-1:0] wdata,
  input  wire         we,
  output wire [W-1:0] rdata
);
  localparam AW = $clog2(N);
  // Highest legal address. The guard is live for non-power-of-2 banks
  // (e.g. N=36864); lint sees only the all-ones power-of-2 default.
  /* verilator lint_off CMPCONST */
  localparam [AW-1:0] N_MAX = N[AW-1:0] - 1'd1;
  /* verilator lint_on CMPCONST */
  reg [W-1:0] mem [0:N-1];
  reg [W-1:0] rdata_q;
  integer i;

  initial begin
    for (i = 0; i < N; i = i + 1) mem[i] = {W{1'b0}};
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  /* verilator lint_off CMPCONST */
  always @(posedge clk) begin
    if (we && (wa <= N_MAX)) mem[wa] <= wdata;
    if (we && (wa == ra) && (wa <= N_MAX))
      rdata_q <= wdata;
    else if (ra <= N_MAX)
      rdata_q <= mem[ra];
    else
      rdata_q <= {W{1'b0}};
  end
  /* verilator lint_on CMPCONST */

  assign rdata = rdata_q;
endmodule
