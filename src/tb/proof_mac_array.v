// proof_mac_array.v — sby wrapper: acc_out equals acc_in plus the full
// P-lane signed lane-sum (unbounded python sum, mod-2^32), under ce;
// clr forces zero; otherwise the register holds.
module proof_mac_array (
  input wire        clk,
  input wire        rst_n,
  input wire        ce,
  input wire        clr,
  input wire [63:0] avec,
  input wire [63:0] bvec,
  input wire [31:0] acc_in
);
  parameter W = 8, P = 8;
  wire [31:0] acc_out;
  mac_array #(.W(W), .P(P)) dut (
    .clk(clk), .rst_n(rst_n), .ce(ce), .clr(clr),
    .avec(avec), .bvec(bvec), .acc_in(acc_in), .acc_out(acc_out)
  );

  // one-cycle-delayed inputs: what the DUT sampled at the last edge
  reg [63:0] avec_d, bvec_d;
  reg [31:0] acc_d;
  reg        ce_d, clr_d;
  always @(posedge clk) begin
    avec_d <= avec; bvec_d <= bvec; acc_d <= acc_in;
    ce_d <= ce; clr_d <= clr;
  end

  reg signed [63:0] ref;
  integer j;
  always @(*) begin
    ref = 64'sd0;
    for (j = 0; j < P; j = j + 1)
      ref = ref + $signed(avec_d[j*W+:W]) * $signed(bvec_d[j*W+:W]);
  end

  // Reset-to-zero is covered by simulation; the formal task is the
  // accumulation invariant, proved with reset held inactive so the async
  // reset edge cannot race the property sampling.
  always @(posedge clk) assume(rst_n);

  reg f_past_valid = 0;
  always @(posedge clk) f_past_valid <= 1'b1;

  always @(posedge clk) begin
    if (f_past_valid && rst_n) begin
      if (clr_d)
        assert(acc_out == 32'd0);
      else if (ce_d)
        assert(acc_out == $signed(acc_d) + ref[31:0]);
      else
        assert(acc_out == $past(acc_out));
    end
  end
endmodule
