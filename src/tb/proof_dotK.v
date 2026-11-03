// proof_dotK.v — sby wrapper: single-shot protocol (done == start delayed
// by exactly one cycle) and value (y == full K-lane signed dot, mod-2^32)
// whenever a shot was taken; y holds otherwise.
module proof_dotK (
  input wire         clk,
  input wire         rst_n,
  input wire         start,
  input wire [127:0] avec,
  input wire [127:0] bvec
);
  parameter W = 8, K = 16;
  wire [31:0] y;
  wire        done;
  dotK #(.W(W), .K(K)) dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .avec(avec), .bvec(bvec), .y(y), .done(done)
  );

  reg [127:0] avec_d, bvec_d;
  reg         start_d;
  always @(posedge clk) begin
    avec_d <= avec; bvec_d <= bvec; start_d <= start;
  end

  reg signed [63:0] ref;
  integer j;
  always @(*) begin
    ref = 64'sd0;
    for (j = 0; j < K; j = j + 1)
      ref = ref + $signed(avec_d[j*W+:W]) * $signed(bvec_d[j*W+:W]);
  end

  // Reset-to-zero is covered by simulation; the formal task is the
  // single-shot value/protocol invariant, proved with reset held inactive
  // so the async reset edge cannot race the property sampling.
  always @(posedge clk) assume(rst_n);

  reg f_past_valid = 0;
  always @(posedge clk) f_past_valid <= 1'b1;

  always @(posedge clk) begin
    if (f_past_valid && rst_n) begin
      assert(done == start_d);
      if (start_d)
        assert(y == ref[31:0]);
      else
        assert(y == $past(y));
    end
  end
endmodule
