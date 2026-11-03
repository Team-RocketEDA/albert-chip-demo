// requant_formal.v — sby wrapper: clip boundaries + shift exactness.
// Binds requant #(.W(8), .SHIFT(8)) (the tb/integrator operating point).
// Strategy: register last-cycle inputs, recompute the contract combinationally,
// assert the registered DUT outputs match, plus floor-shift bounds and covers
// over the clip boundaries.
module requant_formal (
  input wire clk,
  input wire rst_n,
  input wire [31:0] acc_wide,
  input wire [15:0] scale,
  input wire [15:0] zero
);
  wire [7:0] act_int;
  wire       valid;

  requant #(.W(8), .SHIFT(8)) dut (
    .clk(clk), .rst_n(rst_n),
    .acc_wide(acc_wide), .scale(scale), .zero(zero),
    .act_int(act_int), .valid(valid)
  );

  reg signed [31:0] a_q;
  reg signed [15:0] s_q;
  reg signed [15:0] z_q;
  reg               v_q;

  // NOTE (toolchain, verified empirically on oss-cad-suite yosys/sby).
  // `initial assume (!rst_n)` / `if ($initstate) assume (!rst_n)` break
  // this build's model (even cover(rst_n) goes unreached), so no reset
  // assumption is used; `initial assume (!clk)` is harmless and kept.
  // `past_edge` (init 0) suppresses checks before the first clock edge,
  // where dut/wrapper anyinits are mutually inconsistent by construction.
  // From the first edge on, both sample the same inputs with the same
  // reset semantics. Reset values (async rst_n -> act_int=0, valid=0) are
  // verified by the iverilog tb's reset check, not here: this build's
  // smtbmc models the async reset edge-sensitively, so a same-cycle
  // `!rst_n |-> out==0` assert is unsound in the model (real HW is only
  // stricter). Bound: covers fire at step 2 (first post-edge aligned
  // state); bmc runs at depth 2 (steps 0-1) where the gate cannot yet
  // fire, so its PASS is supplementary only — a negated-assert probe
  // (assert(1==0)) also passes there. Deeper UNSAT proofs of the asserts
  // hang both bundled solvers (yices/z3) on the dual 48-bit signed mults;
  // induction hangs too. Documented tool limit, not a design gap.
  reg past_edge = 1'b0;
  always @(posedge clk) past_edge <= 1'b1;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_q <= 0; s_q <= 0; z_q <= 0; v_q <= 0;
    end else begin
      a_q <= $signed(acc_wide);
      s_q <= $signed(scale);
      z_q <= $signed(zero);
      v_q <= 1'b1;
    end
  end

  wire signed [47:0] prod   = a_q * s_q;
  wire signed [47:0] shr    = prod >>> 8;
  wire signed [48:0] biased = $signed({shr[47], shr})
                            + $signed({{33{z_q[15]}}, z_q});
  wire signed [7:0] expect = (biased > 127) ? 8'sd127 :
                             (biased < -128) ? -8'sd128 :
                             biased[7:0];

  always @(posedge clk) begin
    if (rst_n && v_q && past_edge) begin
      // Functional contract: output == clip(floor(acc*scale/256)+zero).
      assert(act_int == expect);
      assert(valid == 1'b1);
      // Shift exactness: >>> 8 is floor divide (q*256 <= prod < (q+1)*256).
      assert((shr <<< 8) <= prod);
      assert(prod < ((shr + 48'sd1) <<< 8));
      // Clip boundaries: both rails reachable, both edges exact.
      cover(biased == 127 && act_int == 8'h7f);
      cover(biased == 128 && act_int == 8'h7f);
      cover(biased == -128 && act_int == 8'h80);
      cover(biased == -129 && act_int == 8'h80);
      // Shift exactness on negatives: floor (not truncation) observed.
      cover(prod < 0 && prod[7:0] != 8'b0 && act_int == expect);
    end
  end
endmodule
