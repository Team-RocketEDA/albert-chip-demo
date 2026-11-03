// regfile_dp — §00-E leaf, dual-port scratch (accumulators).
// Behavior: synchronous write (we samples wa/wdata at posedge clk),
// asynchronous dual read (rda/rdb follow ra/rb combinationally) with
// same-cycle write-forward bypass (we && wa==ra -> rda==wdata, same for rb).
// Out-of-range addresses read as zero and writes to them are dropped.
// INIT_FILE optionally preloads the file with a $readmemh hex image
// (one W-bit word per line); "" keeps zeros.
// Ports and W/N parameters are unchanged from the skeleton contract.
module regfile_dp #(
  parameter W = 32,
  parameter N = 256,
  parameter INIT_FILE = ""
)(
  input  wire         clk,
  input  wire [$clog2(N)-1:0] ra,
  input  wire [$clog2(N)-1:0] rb,
  input  wire [$clog2(N)-1:0] wa,
  input  wire [W-1:0] wdata,
  input  wire         we,
  output wire [W-1:0] rda,
  output wire [W-1:0] rdb
);
  localparam AW = $clog2(N);
  // Highest legal address. The guard is live for non-power-of-2 files;
  // lint sees only the all-ones power-of-2 default.
  /* verilator lint_off CMPCONST */
  localparam [AW-1:0] N_MAX = N[AW-1:0] - 1'd1;
  /* verilator lint_on CMPCONST */
  reg [W-1:0] mem [0:N-1];
  integer i;

  initial begin
    for (i = 0; i < N; i = i + 1) mem[i] = {W{1'b0}};
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  /* verilator lint_off CMPCONST */
  always @(posedge clk) begin
    if (we && (wa <= N_MAX)) mem[wa] <= wdata;
  end

  wire hit_a = we && (wa == ra) && (wa <= N_MAX);
  wire hit_b = we && (wa == rb) && (wa <= N_MAX);

  assign rda = (ra > N_MAX) ? {W{1'b0}} : (hit_a ? wdata : mem[ra]);
  assign rdb = (rb > N_MAX) ? {W{1'b0}} : (hit_b ? wdata : mem[rb]);
  /* verilator lint_on CMPCONST */
endmodule
