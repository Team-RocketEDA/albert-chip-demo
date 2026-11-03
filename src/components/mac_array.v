// mac_array — §00-E leaf. P-wide parallel MACs: 1 MAC/cycle/PE.
// acc_out = acc_in + sum(a[i]*b[i]), signed, exact mod-2^32 wrap.
// Lanes fold the K dimension P ways (cycles/P per dot); cross-cycle and
// cross-chunk accumulation folds through acc_in from the caller regfile.
// Registered output: async reset (rst_n) or sync clr -> 0; else if ce ->
// acc_in + lane-sum; else hold. Internal sum carries 64-bit headroom so
// lane reduction cannot overflow before the mod-2^32 truncation.
module mac_array #(
  parameter W = 8,
  parameter P = 32
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             ce,
  input  wire             clr,
  input  wire [P*W-1:0]   avec,
  input  wire [P*W-1:0]   bvec,
  input  wire [31:0]      acc_in,
  output wire [31:0]      acc_out
);
  reg signed [31:0] acc_r;
  assign acc_out = acc_r;

  reg signed [63:0] psum;
  integer i;
  always @(*) begin
    psum = 64'sd0;
    for (i = 0; i < P; i = i + 1)
      psum = psum + $signed(avec[i*W+:W]) * $signed(bvec[i*W+:W]);
  end

  // acc_in (32-bit signed) intentionally sign-extends into the 64-bit
  // lane-sum add; low 32 bits are the exact mod-2^32 verdict.
  // Proven by src/tb/mac_array.sby.
  /* verilator lint_off WIDTHEXPAND */
  wire signed [63:0] acc_ext;
  assign acc_ext = $signed(acc_in) + psum;
  /* verilator lint_on WIDTHEXPAND */

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      acc_r <= 32'sd0;
    else if (clr)
      acc_r <= 32'sd0;
    else if (ce)
      acc_r <= acc_ext[31:0];
  end
endmodule
