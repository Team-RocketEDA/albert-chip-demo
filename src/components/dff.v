// dff — §00-E leaf: W-wide pipeline register, async active-low reset.
// Contract: blocks/00-primitive-library.md §E (`Q=D` @clk). Toggle chain
// (Qbar→D) is a wiring pattern in the parent, not implemented here.
module dff #(
  parameter W = 8
)(
  input  wire         clk,
  input  wire         rst_n,
  input  wire [W-1:0] d,
  output wire [W-1:0] q
);
  reg [W-1:0] q_q;

  assign q = q_q;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      q_q <= {W{1'b0}};
    else
      q_q <= d;
  end

`ifdef FORMAL
  // Formal properties (sby): reset dominance + Q=D (BMC depth 5).
  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;

  always @(posedge clk) begin
    // A reset edge takes effect by the next edge: past-rst implies q==0.
    if (f_past_valid && !$past(rst_n))
      assert(q == {W{1'b0}});
    // Normal operation: q follows d by one cycle.
    if (f_past_valid && $past(rst_n) && rst_n)
      assert(q == $past(d));
    cover(f_past_valid && rst_n && (q != {W{1'b0}}));
  end
`endif
endmodule
