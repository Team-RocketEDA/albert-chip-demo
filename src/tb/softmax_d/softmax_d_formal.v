// softmax_d_formal — sby wrapper (S=4): valid 1-cycle delay, causal
// masked-zero, row-counter wrap. SCOPE: exp_lut is blackboxed (see
// softmax.sby), so this proves control/safety, not arithmetic — per-lane
// bounds and row-sum exactness are proven instead by tb_softmax_d.v against
// the independent float golden (24 rows x 2 causal modes + S=64 smoke).
// Strategy: proof starts from reset (release is solver-chosen). Masked-zero
// is checked on the COMBINATIONAL probs_comb image against the CURRENT
// row_q/causal (no tracking registers, so back-to-back accepts cannot
// skew it); validity is the 1-cycle-delayed accept, armed by two clean
// posedges. Masked-zero needs only the mask mux + divider zero path
// (div(0, den) == 0 with den >= 1 by the exp-range assumes), so it stays
// meaningful with a symbolic exp.
module softmax_d_formal (
  input wire clk,
  input wire rst_n,
  input wire [4*16-1:0] scores,
  input wire scores_valid,
  input wire causal
);
  localparam S = 4;
  wire [S*16-1:0] probs;
  wire probs_valid;

  softmax_d #(.W(16), .S(S)) dut (
    .clk(clk), .rst_n(rst_n),
    .scores(scores), .scores_valid(scores_valid), .causal(causal),
    .probs(probs), .probs_valid(probs_valid)
  );

  // Proof starts from reset (release is solver-chosen); without this the
  // solver begins in an arbitrary unreset state and the checks are vacuous.
  initial assume (!rst_n);

  reg f_valid = 1'b0;
  reg past_sv = 1'b0;
  // Async reset clears probs_valid outside the clocked path, so the delay
  // property is only meaningful after two clean posedges. The arming
  // counter is cleared by ANY negedge (even mid-cycle glitches the
  // posedge-sampled logic cannot see) and re-arms after two clean edges.
  // (No accept-tracking registers: the data checks below read the
  // combinational probs_comb against same-cycle row_q/causal, so they
  // cannot skew under back-to-back accepts.)
  reg [1:0] clean = 2'b00;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) clean <= 2'b00;
    else clean <= {clean[0], 1'b1};
  end

  wire [S*16-1:0] probs_comb = dut.probs_comb;

  // Blackbox contract for exp_lut: image [1, 4096] (already proven by
  // src/tb/exp_lut/exp_lut.sby on the real table). Without it the solver
  // could pick all-zero exps (sum = 0), which the real LUT never emits.
  genvar h;
  generate
    for (h = 0; h < S; h = h + 1) begin : g_exp_range
      always @(posedge clk) begin
        assume(dut.g_exp[h].u_exp.y >= 16'd1);
        assume(dut.g_exp[h].u_exp.y <= 16'd4096);
      end
    end
  endgenerate

  always @(posedge clk) begin
    f_valid <= 1'b1;
    past_sv <= scores_valid && rst_n;
    if (f_valid && clean == 2'b11) begin
      // 1-cycle latency: valid is last cycle's (gated) accept.
      assert(probs_valid == past_sv);
    end
    if (f_valid && rst_n) begin
      // Same-cycle combinational check: the mask uses the CURRENT row
      // counter and causal flag, so masked lanes of the CURRENT
      // probs_comb image must read exactly zero (lane 0 is never masked:
      // row_q <= 3). Masked-zero needs only the mask mux + divider zero
      // path (div(0, den) == 0 with den >= 1 by the exp-range assumes).
      if (causal && 1 > dut.row_q)
        assert(probs_comb[1*16 +: 16] == 16'h0000);
      if (causal && 2 > dut.row_q)
        assert(probs_comb[2*16 +: 16] == 16'h0000);
      if (causal && 3 > dut.row_q)
        assert(probs_comb[3*16 +: 16] == 16'h0000);
      // Reachability: the counter visits every row, and the causal mask
      // engages on row 0 (full-mass arithmetic reachability is covered
      // by the golden sim, not by a symbolic-exp cover).
      cover(dut.row_q == 2'd3);
      cover(causal && dut.row_q == 2'd0);
    end
  end
endmodule
