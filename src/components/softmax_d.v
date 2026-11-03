// softmax_d — causal row-softmax datapath (MobileLLM decoder attention).
// Contract: blocks/03-attention-core.md softmax_pipe + step 9 acceptance
// (vs python float softmax within 16 LSB Q4.12, causal mask enforced,
// row-sum ~= 1.0).
//
// Fixed-point contract: scores/probs Q4.12 signed16 (code/4096,
// range [-8.0, +7.99976]). Pipe per accepted row:
//   eff = masked ? -8.0 : score        (causal mask add, inferred)
//   m   = max(eff)                     (inferred compare chain)
//   e   = exp_lut(eff - m); masked lanes forced to exactly 0
//   s   = sum(e)                       (inferred add chain, 24b)
//   p   = round(e * 4096 / s)          (exact restoring divider, inferred)
// probs/probs_valid register one cycle after scores_valid (level accept).
//
// Causal semantic: rows are consumed in accept order; an internal row
// counter (accepts since reset, mod S) is the row index. Lane j is masked
// iff causal && j > row. attention_core ties causal=1 (decode safe).
// First row after reset is row 0 -> [1.0, 0, ...] whatever the scores.
//
// Reciprocal note: the div_unit child is instantiated for hierarchy
// continuity (same ports as the skeleton), but the datapath uses its own
// exact per-lane restoring divider so this block verifies standalone
// before div_unit (step 11) lands; the integrator may re-point the
// reciprocal at a shared div_unit without changing ports or behavior.
// All arithmetic operators are inferred (+, -, *, >>>, ?:); no
// single-operator modules, per blocks/00-primitive-library.md §E.
module softmax_d #(
  parameter W = 16,
  parameter S = 64
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire [S*W-1:0]   scores,
  input  wire             scores_valid,
  input  wire             causal,
  output wire [S*W-1:0]   probs,
  output wire             probs_valid
);
  localparam integer ROWW = (S > 1) ? $clog2(S) : 1;
  // -8.0 floor doubles as the masked-lane stand-in: it can never exceed a
  // real max (scores bottom out at -8.0), and masked lanes are forced to
  // prob 0 after exp anyway.
  localparam signed [W-1:0] NEG_INF = -16'sd32768; // 0x8000 = -8.0 Q4.12

  // ---- accept-order row counter (the causal row index) ----
  reg [ROWW-1:0] row_q;

  // ---- lane unpack + causal mask ----
  // Lane 0 is never masked (row_q >= 0), so it gets a dedicated branch;
  // the general lanes compare 32b-extended indices (verilator-clean).
  wire signed [W-1:0] sc [0:S-1];
  wire signed [W-1:0] eff [0:S-1];   // masked scores into the max tree
  wire                masked [0:S-1];
  wire [31:0] row_ext = {{(32-ROWW){1'b0}}, row_q};
  genvar g;
  generate
    for (g = 0; g < S; g = g + 1) begin : g_unpack
      localparam integer GJ = g;
      assign sc[g] = $signed(scores[GJ*W +: W]);
    end
    for (g = 0; g < S; g = g + 1) begin : g_mask
      if (g == 0) begin : g_m0
        assign masked[0] = 1'b0;
        assign eff[0]    = sc[0];
      end else begin : g_mn
        localparam integer GJ = g;
        wire [31:0] gj = GJ;
        assign masked[GJ] = causal & (gj > row_ext);
        assign eff[GJ]    = masked[GJ] ? NEG_INF : sc[GJ];
      end
    end
  endgenerate

  // ---- row max over masked scores (inferred compare chain) ----
  wire signed [W-1:0] mx [0:S-1];
  assign mx[0] = eff[0];
  generate
    for (g = 1; g < S; g = g + 1) begin : g_max
      assign mx[g] = (eff[g] > mx[g-1]) ? eff[g] : mx[g-1];
    end
  endgenerate
  wire signed [W-1:0] row_max = mx[S-1];

  // ---- max-sub + exp LUT (one instance per lane, S replicates) ----
  wire signed [W-1:0] sub_e [0:S-1];
  wire [W-1:0]        exp_e [0:S-1]; // raw LUT output (masked discarded)
  wire [W-1:0]        ee [0:S-1];    // masked lanes forced to exactly 0
  generate
    for (g = 0; g < S; g = g + 1) begin : g_exp
      // Score spread can reach 16.0 ([-8, +8]) but exp_lut spans [-8, 0]:
      // saturate differences below -8.0 at the floor (exp = 1 LSB ~= 0).
      // Masked lanes may go positive here; their exp is discarded by the
      // masked mux below (exp_lut clamps positives to 0x1000).
      wire signed [16:0] sub17 = $signed({eff[g][W-1], eff[g]})
                               - $signed({row_max[W-1], row_max});
      wire below_floor = sub17[16] & ~sub17[15]; // sub17 < -32768
      assign sub_e[g] = below_floor ? NEG_INF : sub17[W-1:0];
      exp_lut #(.W(W)) u_exp (.x(sub_e[g]), .y(exp_e[g]));
      assign ee[g] = masked[g] ? {W{1'b0}} : exp_e[g];
    end
  endgenerate

  // ---- row sum of exps (inferred add chain, unsigned 24b) ----
  // Peak: S=64 lanes x 0x1000 = 262144 < 2^18; 24b holds any S<=4096.
  wire [23:0] exp_sum [0:S-1];
  assign exp_sum[0] = {{(24-W){1'b0}}, ee[0]};
  generate
    for (g = 1; g < S; g = g + 1) begin : g_sum
      assign exp_sum[g] = exp_sum[g-1] + {{(24-W){1'b0}}, ee[g]};
    end
  endgenerate
  wire [23:0] sum_w = exp_sum[S-1];

  // ---- exact per-lane division p = round(e*4096/sum), half-up ----
  // Restoring divider over 25b (unrolled combinationally); sum >= 1 always
  // (lane 0 is never masked, exp(.) >= 1 LSB), zero-guarded anyway.
  // num = e*4096 peaks at exactly 2^24 (e = 0x1000), so the datapath is
  // 25b; den = sum < 2^19. quo <= 4096 by construction (num/den <= 1).
  function [15:0] div_rnd_q12;
    input [24:0] num;
    input [24:0] den;
    reg [25:0] rem;
    reg [24:0] quo;
    reg [15:0] rnd;
    integer k;
    begin
      rem = 26'd0;
      quo = 25'd0;
      for (k = 24; k >= 0; k = k - 1) begin
        rem = {rem[24:0], num[k]};
        if (rem >= {1'b0, den}) begin
          rem = rem - {1'b0, den};
          quo[k] = 1'b1;
        end
      end
      // Round half up: carry iff 2*rem >= den, evaluated as
      // rem >= den - rem (27b, no overflow possible).
      rnd = 16'd0;
      if ({1'b0, rem} >= ({2'b0, den} - {1'b0, rem}))
        rnd = 16'd1;
      // Saturate the +1 path (only reachable when quo == 4096, rem == 0
      // forces rnd = 0, so this is dead-safe).
      if (quo[24:16] != 9'd0 || (quo[15:0] == 16'd4096))
        div_rnd_q12 = 16'd4096;
      else
        div_rnd_q12 = quo[15:0] + rnd;
    end
  endfunction

  wire [W-1:0] norm_full [0:S-1];
  generate
    for (g = 0; g < S; g = g + 1) begin : g_norm
      // e[g] <= 4096 so e*4096 <= 2^24 exactly (needs the 25th bit);
      // inferred mult.
      wire [24:0] num_w = ee[g] * 25'd4096;
      wire [24:0] den_w = {1'b0, sum_w};
      assign norm_full[g] = masked[g] ? {W{1'b0}} : div_rnd_q12(num_w, den_w);
    end
  endgenerate

  // Pack probs (combinational image of the accepted row).
  wire [S*W-1:0] probs_comb;
  generate
    for (g = 0; g < S; g = g + 1) begin : g_pack
      assign probs_comb[g*W +: W] = norm_full[g];
    end
  endgenerate

  // div_unit child: hierarchy continuity with the skeleton wiring plan.
  // numer = 1.0 Q4.12, denom = row exp-sum; outputs unconnected — the exact
  // per-lane divider above is the authoritative reciprocal (see header).
  div_unit #(.W(24)) u_recip (
    .clk(clk), .rst_n(rst_n), .start(scores_valid),
    .numer(24'h001000), .denom(sum_w),
    .quot(), .done()
  );

  // ---- output registers: 1-cycle latency, level accept ----
  reg [S*W-1:0] probs_q;
  reg           valid_q;
  // Wrap test in the 32b domain (no truncation, no width mismatch).
  wire wrap_at = (row_ext == (S-1));
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      probs_q <= {S*W{1'b0}};
      valid_q <= 1'b0;
      row_q   <= {ROWW{1'b0}};
    end else begin
      valid_q <= scores_valid;
      if (scores_valid) begin
        probs_q <= probs_comb;
        row_q   <= wrap_at ? {ROWW{1'b0}} : (row_q + {{(ROWW-1){1'b0}}, 1'b1});
      end
    end
  end

  assign probs = probs_q;
  assign probs_valid = valid_q;
endmodule
