// requant — §00-E leaf. Accum-to-int8 rescale.
// Contract: blocks/00-primitive-library.md §E, PARAMS §2/§3,
// 02-inproj-tile.md §6, 05-rmsnorm.md §7, 09-interface.md #6.
//
// y = clip_W((acc_wide * scale) >>> SHIFT + zero)
//
// - acc_wide : signed 32-bit MAC accumulator (int8 x int8 -> s32, exact).
// - scale    : signed 16-bit fixed-point multiplier. Q8.8 convention
//              (scale=256 <=> x1.0 gain); SHIFT selects the binary point.
// - zero     : signed 16-bit offset added AFTER the shift (per-use bias).
// - >>>      : arithmetic shift = exact floor divide by 2^SHIFT.
// - clip_W   : saturate to the signed W-bit range (W=8 -> [-128, 127]).
// - SHIFT    : elaboration-time shift (per-use sweep, PARAMS §2/§9).
//              Default 8 pairs with the Q8.8 scale convention.
// One registered stage: act_int/valid update 1 cycle after the inputs
// are sampled. There is no input-valid handshake on this leaf (the
// skeleton carries none); valid == 1 whenever the block is out of reset.
// All operators are inferred (+, *, >>>, compares) per the §00-E rule.
module requant #(
  parameter W = 8,
  parameter SHIFT = 8
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire [31:0]      acc_wide,
  input  wire [15:0]      scale,
  input  wire [15:0]      zero,
  output wire [W-1:0]     act_int,
  output wire             valid
);
  // ---- combinational core (formal target) ----
  wire signed [31:0] acc_s   = $signed(acc_wide);
  wire signed [15:0] scale_s = $signed(scale);
  wire signed [15:0] zero_s  = $signed(zero);

  // 32b x 16b -> full 48b product (exact, no rounding here).
  wire signed [47:0] prod = acc_s * scale_s;
  // Arithmetic shift: exact floor(prod / 2^SHIFT), sign-preserving.
  wire signed [47:0] shr  = prod >>> SHIFT;
  // Widen before the offset add so the addition itself cannot wrap.
  wire signed [48:0] biased = $signed({shr[47], shr})
                            + $signed({{33{zero_s[15]}}, zero_s});

  // Signed W-bit saturating bounds, e.g. W=8 -> HI=127, LO=-128.
  localparam signed [48:0] HI = (49'sd1 << (W-1)) - 49'sd1;
  localparam signed [48:0] LO = -(49'sd1 << (W-1));

  wire signed [W-1:0] clipped = (biased > HI) ? HI[W-1:0] :
                                (biased < LO) ? LO[W-1:0] :
                                biased[W-1:0];

  // ---- single registered stage (uses clk/rst_n) ----
  reg [W-1:0] q_r;
  reg         v_r;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_r <= {W{1'b0}};
      v_r <= 1'b0;
    end else begin
      q_r <= clipped;
      v_r <= 1'b1;
    end
  end

  assign act_int = q_r;
  assign valid   = v_r;
endmodule
