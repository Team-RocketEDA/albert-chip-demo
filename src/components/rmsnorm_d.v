// rmsnorm_d — MobileLLM RMSNorm datapath (logic implementation).
// Contract: architecture/blocks/05-rmsnorm.md + blocks contract header:
//   y = x / sqrt(mean(x^2) + eps) * g, eps=1e-5. NO mean subtraction,
//   NO beta. DTYPE: FXP16 Q8.8 on all ports; ACC guard wider inside.
// Protocol (framed streaming, back-to-back, no sidebands): after rst_n
//   the DUT idles exactly one clock (it resets into end-of-frame), then
//   LOAD samples one (x,resid,gamma) lane per clock for D lanes, then
//   1 CALC + 4 NR + 1 DENORM clocks, then OUT streams D lanes with
//   y_valid=1, then the next frame's LOAD starts immediately (the
//   OUT->LOAD edge cycle samples nothing). Frame period = 2*D + 6.
//   The testbench presents lane0 one clock after each frame boundary.
// Datapath (all operators inferred +,-,*,if/case; no single-op modules):
//   t   = sat16(x + resid)                       (RES_ADD)
//   S   = sum over frame of t*t, exact 48-bit    (SQR_MEAN)
//   A   = S + 377, folding mean+eps exactly:
//         1/sqrt(S/(D*65536) + eps) = 6144/sqrt(S + eps*D*65536),
//         D = 576: 576*65536 = 37748736, sqrt = 6144 exact;
//         eps*D*65536 = 377.487 -> 377 (only matters when S ~ 0,
//         where every lane output is ~0 anyway).
//   (e, M) = normalize A: A = m * 2^(e+1), M = m * 2^30 in [2^29,2^30).
//   X  = 4x Newton-Raphson 1/sqrt(m) in Q2.30 from a 16-entry seed ROM
//        indexed by M[28:25] (replaces the skeleton's exp_lut seed tap:
//        exp() cannot seed 1/sqrt; the ROM below holds true 1/sqrt
//        seeds, same inferred-ops-only rule).
//   rsc = X narrowed to UQ2.14 (rel err <= 2^-15).
//   xhat_lane = round_half_away(t_lane * rsc * K / 2^14),
//         K = 3 * 2^(11-(e+1)/2) (e odd) or 3*sqrt(2) * 2^(10-e/2)
//         (e even): the 3 is 6144 = 3 * 2^11, sqrt(2) corrects odd e+1.
//   af  = xhat * gamma (exact 32-bit); y = sat16(round_half_away(af/256)).
// Error vs float RMSNorm: <= 1 LSB on the baked 576-lane vector and on
// zero/one/max/min/spike/tiny synthetic frames (see tb + prototype note
// in src/tb/rmsnorm_d/). Gamma arrives Q8.8 (round(g*256)); its 0.5-LSB
// quantisation is the dominant term and is inside the 3-LSB tb budget.
// Ports and the t/sq/nm/af/y/xhat/var_v/rsqrt wire set follow the
// skeleton; only the exp_lut seed instance is removed (see above).
module rmsnorm_d #(
  parameter W = 16,
  parameter D = 576
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire [W-1:0]     x,
  input  wire [W-1:0]     resid,
  input  wire [W-1:0]     gamma,
  output wire [W-1:0]     y,
  output wire             y_valid
);
  // ---- state ----
  localparam [2:0] ST_LOAD = 3'd0,
                   ST_CALC = 3'd1,
                   ST_NR   = 3'd2,
                   ST_DEN  = 3'd3,
                   ST_OUT  = 3'd4;
  localparam signed [31:0] SQRT2_C = 32'd1520270860; // round(sqrt(2)*2^30)

  reg [2:0] state;
  reg [9:0] cnt; // sized for D <= 1024
  reg [1:0] nrc;
  reg signed [15:0] tmem [0:D-1];
  reg signed [15:0] gmem [0:D-1];
  reg [47:0] sumsq;
  reg [39:0] accA; // debug view of S + 377
  reg [5:0]  expE;
  reg [29:0] mantM;
  reg [30:0] nrX;
  reg [15:0] rsc;
  reg [5:0]  esave;

  wire [W-1:0]     t;
  wire [W-1:0]     var_v;
  wire [W-1:0]     rsqrt;
  wire [W-1:0]     xhat;
  wire [2*W-1:0]   sq;
  wire [2*W-1:0]   nm;
  wire [2*W-1:0]   af;

  // ---- helpers (inferred ops only) ----
  function signed [15:0] sat16(input signed [16:0] v);
    begin
      if (v > 17'sd32767)       sat16 = 16'h7fff;
      else if (v < -17'sd32768) sat16 = 16'h8000;
      else                      sat16 = v[15:0];
    end
  endfunction

  function [5:0] bitlen40(input [39:0] v); // floor(log2(v)) for v >= 1
    integer k;
    begin
      bitlen40 = 6'd0;
      for (k = 0; k <= 39; k = k + 1) // ascending: last write = top bit
        if (v[k]) bitlen40 = k[5:0];
    end
  endfunction

  // True 1/sqrt seeds: ROM[i] = round(2^30 / sqrt((i + 16.5) / 32)),
  // the midpoint of mantissa bin i (same method as the exp/silu table
  // oracles: pure-python, generated once, pasted here).
  function [30:0] seed_of(input [3:0] idx);
    begin
      case (idx)
        4'd0:  seed_of = 31'd1495315679;
        4'd1:  seed_of = 31'd1451963954;
        4'd2:  seed_of = 31'd1412176548;
        4'd3:  seed_of = 31'd1375490368;
        4'd4:  seed_of = 31'd1341522400;
        4'd5:  seed_of = 31'd1309952745;
        4'd6:  seed_of = 31'd1280511845;
        4'd7:  seed_of = 31'd1252970736;
        4'd8:  seed_of = 31'd1227133513;
        4'd9:  seed_of = 31'd1202831433;
        4'd10: seed_of = 31'd1179918260;
        4'd11: seed_of = 31'd1158266544;
        4'd12: seed_of = 31'd1137764631;
        4'd13: seed_of = 31'd1118314230;
        4'd14: seed_of = 31'd1099828424;
        default: seed_of = 31'd1082230034;
      endcase
    end
  endfunction

  // Round-half-away-from-zero of v / 2^k, k >= 1 (65-bit core).
  function signed [64:0] rha65(input signed [64:0] v, input [5:0] k);
    reg signed [64:0] half;
    begin
      half = 65'sd1 << (k - 6'd1);
      rha65 = (v >= 0) ? ((v + half) >>> k) : (-(((-v) + half) >>> k));
    end
  endfunction

  // ---- LOAD add/square ----
  wire signed [16:0] t_sum = $signed(x) + $signed(resid);
  wire signed [15:0] t_sat = sat16(t_sum);
  wire signed [31:0] sq_full = t_sat * t_sat;
  assign t  = t_sat;
  assign sq = sq_full[31:0];

  // ---- CALC combinational (normalize + seed) ----
  // sumsq < 2^40 always (<= D lanes of max energy, asserted under FORMAL),
  // so the low 40 bits are exact; M < 2^30 by normalization; NR quantities
  // stay in range (X <= sqrt(2)*2^30), so every low-bit select below is
  // exact, never a wrap.
  wire [39:0] calcA = sumsq[39:0] + 40'd377;
  wire [5:0]  calcE = bitlen40(calcA);
  wire [39:0] calcM_wide = (calcE <= 6'd29) ?
                      (calcA << (6'd29 - calcE)) : (calcA >> (calcE - 6'd29));
  wire [29:0] calcM = calcM_wide[29:0];

  // Q2.30 -> UQ2.14 narrowing (registered in ST_DEN).
  wire [31:0] den_wide = (nrX + 31'd32768) >> 16;

  // ---- rsqrt Newton-Raphson next step (registered in ST_NR) ----
  wire [61:0] nr_p_full = nrX * nrX;
  wire [61:0] nr_p_wide = (nr_p_full + 62'd1073741824) >> 30;
  wire [31:0] nr_p = nr_p_wide[31:0];
  wire [61:0] nr_q_full = mantM * nr_p;
  wire [61:0] nr_q_wide = (nr_q_full + 62'd1073741824) >> 30;
  wire [31:0] nr_q = nr_q_wide[31:0];
  wire [31:0] nr_d3 = 32'd3221225472 - nr_q;
  wire [62:0] nr_xn_full = nrX * nr_d3;
  wire [62:0] nr_xn_wide = (nr_xn_full + 63'd1073741824) >> 31;
  wire [30:0] nr_xn = nr_xn_wide[30:0];

  // ---- OUT lane datapath ----
  wire signed [15:0] lane_t = tmem[cnt];
  wire signed [15:0] lane_g = gmem[cnt];
  wire signed [31:0] prod32 = lane_t * $signed({1'b0, rsc});
  assign nm = prod32[31:0];
  wire signed [32:0] p3 = prod32 * 33'sd3;
  wire signed [64:0] p3e = {{32{p3[32]}}, p3};
  wire signed [64:0] p2full = p3e * SQRT2_C;
  wire signed [64:0] p2 = rha65(p2full, 6'd30);
  wire signed [64:0] xh_full = esave[0] ?
        rha65(p3e, 6'd3 + ((esave + 6'd1) >> 1)) :
        rha65(p2, 6'd4 + (esave >> 1));
  wire signed [15:0] xh_sat = (xh_full > 65'sd32767) ? 16'h7fff :
                              (xh_full < -65'sd32768) ? 16'h8000 :
                              xh_full[15:0];
  assign xhat = xh_sat;
  wire signed [31:0] af_full = xh_sat * lane_g;
  assign af = af_full[31:0];
  wire signed [64:0] afe = {{33{af_full[31]}}, af_full};
  wire signed [64:0] y_full = rha65(afe, 6'd8);
  wire signed [15:0] y_sat = (y_full > 65'sd32767) ? 16'h7fff :
                             (y_full < -65'sd32768) ? 16'h8000 :
                             y_full[15:0];
  assign y = y_sat;
  assign y_valid = (state == ST_OUT);

  // Normalized mantissa view (seed-ROM tap of the accumulated mean).
  assign var_v = mantM[29:14];
  assign rsqrt = rsc;

  // ---- formal properties (sby only; compiled out of sim/synth) ----
  // Bound here instead of a separate *_formal.v: this yosys flow
  // mis-resolves hierarchical refs into the DUT (1-bit undriven
  // aliases), while locals need no hierarchy at all.
`ifdef FORMAL
  reg [15:0] f_pulses;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) f_pulses <= 0;
    else if (y_valid) f_pulses <= f_pulses + 1'b1;
  end
  initial assume (!rst_n); // BMC starts in async reset: all driven
  assert property (y_valid == (state == ST_OUT)); // framing safety
  assert property (sumsq <= (48'd1073741824 * D)); // <= D lanes of max energy
  assert property (cnt <= D - 1); // lane counter range
  // X-freedom of every valid lane is proven by the iverilog tb instead
  // (^y === 1'bx checks on all 2304 collected lanes): $isunknown does
  // not elaborate soundly in this yosys/smtbmc version (spurious step-0
  // failure with the same assume/reset that framing/sumsq/cnt pass).
  cover property (f_pulses == D); // one full frame; back-to-back framing is sim-covered (tb runs consecutive frames)
`endif

  // ---- control ----
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Reset into end-of-frame: the first posedge takes OUT->LOAD
      // (sampling nothing), so every frame — including the first —
      // presents lane0 exactly one clock after its boundary.
      state <= ST_OUT;
      cnt   <= D - 1;
      nrc   <= 2'd0;
      sumsq <= 48'd0;
      accA  <= 40'd0;
      expE  <= 6'd0;
      mantM <= 30'd0;
      nrX   <= 31'd0;
      rsc   <= 16'd0;
      esave <= 6'd0;
    end else begin
      case (state)
        ST_LOAD: begin
          tmem[cnt] <= t_sat;
          gmem[cnt] <= $signed(gamma);
          sumsq <= sumsq + {16'd0, sq_full};
          if (cnt == D - 1) begin
            cnt   <= 10'd0;
            state <= ST_CALC;
          end else begin
            cnt <= cnt + 10'd1;
          end
        end
        ST_CALC: begin
          accA  <= calcA;
          expE  <= calcE;
          mantM <= calcM;
          nrX   <= seed_of(calcM[28:25]);
          nrc   <= 2'd0;
          state <= ST_NR;
        end
        ST_NR: begin
          nrX <= nr_xn;
          if (nrc == 2'd3) begin
            state <= ST_DEN;
          end else begin
            nrc <= nrc + 2'd1;
          end
        end
        ST_DEN: begin
          rsc   <= den_wide[15:0]; // exact: <= 23171
          esave <= expE;
          cnt   <= 10'd0;
          state <= ST_OUT;
        end
        ST_OUT: begin
          if (cnt == D - 1) begin
            cnt   <= 10'd0;
            sumsq <= 48'd0;
            state <= ST_LOAD;
          end else begin
            cnt <= cnt + 10'd1;
          end
        end
        default: begin
          state <= ST_OUT;
          cnt   <= D - 1;
        end
      endcase
    end
  end
endmodule
