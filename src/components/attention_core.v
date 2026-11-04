// attention_core — L1 stitch with real logic (block-logic phase).
// Contract: architecture/blocks/03-attention-core.md (GQA 9Q/3KV heads,
// head_dim 64, causal mask, RoPE on Q/K, KV cache for decode).
// Parent I/O: Q[Sx576]s8, K[Sx192]s8, V[Sx192]s8 -> Y[Sx576]s8.
//
// Datapath (all inferred + - * and if/case; no single-operator modules):
//   u_rope_q/u_rope_k : named generate-looped mult-add rotation pairs,
//     fed by $readmemh Q4.12 ROMs (row = pos*32 + pair, pos 0..63).
//   u_qk (mac_array) : every QK product flows through it; 576-wide dots
//     fold 32-wide x 18 chunks (chunk c = head c>>1, half c&1; KV head
//     (c>>1)>=6?2:(c>>1)>=3?1:0, the GQA thirds). Single-shot reuse,
//     acc_in=0, lane sums folded in acc_qk (exact mod-2^32).
//   scale: L_raw >>> 3 (arith, floor), saturated to s16 Q4.12.
//   u_softmax (causal=1'b1): row-wise prefix softmax. FRAME-START RESET:
//     sm_rst_n pulses low for one cycle at every frame start so row_q == 0
//     for row 0 even after a partial (s_cfg < S) frame (integration trap).
//     Causal mask-before-rowmax lives inside softmax_d.
//   u_score: spills the A[S][S] image (producer/consumer decoupling).
//   u_av (second mac_array): every AV product flows through it; A is Q4.12
//     (13b) so each lane ships as hi/lo byte shots, lo corrected for the
//     mac's signed-lane view (exact: A = hi*256 + lo unsigned).
//   Y requant: y = clip8((acc + 2048) >>> 12), GQA fan-out
//     (Y head h reads V head h/3).
//   Staging: u_qbuf/u_kbuf/u_vbuf written per frame; u_kcache/u_vcache
//     appended at cache_ptr (2048-token window, wraps); u_outfifo streams
//     the Y frame out (rd held with wr: consumer-side flow-through).
// Protocol: hold q_in/k_in/v_in/s_cfg stable from qkv_valid until y_valid.
// qkv_ready = 1 only in IDLE; y_valid pulses 1 cycle per frame.
// Weight-path overrides: VERILOG_DEFINES (LibreLane) or -D (hand flow)
// injects an absolute path; defaults stay repo-root-relative for sim.
`ifndef AC_COS_PATH
`define AC_COS_PATH "weights/bake/rope_cos.hex"
`endif
`ifndef AC_SIN_PATH
`define AC_SIN_PATH "weights/bake/rope_sin.hex"
`endif
module attention_core #(
  parameter S = 64,
  parameter H = 576,
  parameter KV = 192,
  // RoPE table images, repo-root-relative for sim. Formal overrides these
  // with workdir-local basenames (same INIT_FILE pattern as sram_1r1w).
  parameter COS_F = `AC_COS_PATH,
  parameter SIN_F = `AC_SIN_PATH
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire [S*H*8-1:0] q_in,
  input  wire [S*KV*8-1:0] k_in,
  input  wire [S*KV*8-1:0] v_in,
  input  wire             qkv_valid,
  input  wire [6:0]       s_cfg, // S bound config
  output wire             qkv_ready,
  output wire [S*H*8-1:0] y_out,
  output wire             y_valid
);
  localparam integer QW = S*H*8;
  localparam integer KW = S*KV*8;
  localparam integer NWORDS_Q = S*9; // 512b words per Q frame (576B rows)
  localparam [6:0] S7 = S;
  localparam IDLE = 0, RSTRM = 1, CACHEW = 2, QK = 3, SM_S = 4,
               SM_R = 5, SM_W = 6, AV = 7, OUTF = 8, YV = 9;

  // ---- RoPE sin/cos ROMs (Q4.12, 2048 rows) ----
  reg signed [15:0] cos_rom [0:2047];
  reg signed [15:0] sin_rom [0:2047];
  // NETLIST_CLEAN (netlist JSON only): skip ROM preload so the
  // render shows clean blocks. Sim/synth never define it.
  initial begin
`ifndef NETLIST_CLEAN
    $readmemh(COS_F, cos_rom);
    $readmemh(SIN_F, sin_rom);
`endif
  end

  // ---- frame latches ----
  reg [QW-1:0] q_r;
  reg [KW-1:0] k_r;
  reg [KW-1:0] v_r;
  reg [6:0] nrows;
  reg signed [15:0] a_buf [0:S-1][0:S-1];
  reg signed [31:0] l_raw [0:S-1][0:S-1];
  reg [QW-1:0] y_r;
  reg [10:0] cache_ptr;

  // ---- FSM ----
  reg [3:0] state;
  reg [$clog2(S+1)-1:0] qi, qj;
  reg [4:0] qc;
  reg [1:0] qp; // 0 SHOT, 1 WAIT, 2 CAP (mac acc_out is registered)
  reg signed [31:0] acc_qk;
  reg [$clog2(S+1)-1:0] r, w, cr, ai, aj;
  reg [7:0] ad2; // 0..191 over the KV-wide (192) result columns
  reg [2:0] ap; // 0 SHOT_LO 1 WAIT_LO 2 CAP_LO 3 SHOT_HI 4 WAIT_HI 5 CAP_HI
  reg signed [31:0] acc_av, tmp_lo;
  reg [9:0] wq, woc;
  reg yv_q;

  // ---- RoPE rotation pairs (named generate groups, inferred mult-add) ----
  wire [QW-1:0] q_rope;
  wire [KW-1:0] k_rope;
  genvar gp, gh, gt;
  generate
    for (gp = 0; gp < S; gp = gp + 1) begin : u_rope_q
      for (gh = 0; gh < 9; gh = gh + 1) begin : g_h
        for (gt = 0; gt < 32; gt = gt + 1) begin : g_t
          wire signed [7:0] q0 = $signed(q_r[(gp*576+gh*64+2*gt)*8 +: 8]);
          wire signed [7:0] q1 = $signed(q_r[(gp*576+gh*64+2*gt+1)*8 +: 8]);
          wire signed [15:0] cc = cos_rom[gp*32+gt];
          wire signed [15:0] ss = sin_rom[gp*32+gt];
          wire signed [24:0] r0w = (q0*cc - q1*ss) >>> 12;
          wire signed [24:0] r1w = (q0*ss + q1*cc) >>> 12;
          wire [7:0] b0 = (r0w > 127) ? 8'd127 : ((r0w < -128) ? 8'd128 : r0w[7:0]);
          wire [7:0] b1 = (r1w > 127) ? 8'd127 : ((r1w < -128) ? 8'd128 : r1w[7:0]);
          assign q_rope[(gp*576+gh*64+2*gt)*8 +: 8] = b0;
          assign q_rope[(gp*576+gh*64+2*gt+1)*8 +: 8] = b1;
        end
      end
    end
    for (gp = 0; gp < S; gp = gp + 1) begin : u_rope_k
      for (gh = 0; gh < 3; gh = gh + 1) begin : g_h
        for (gt = 0; gt < 32; gt = gt + 1) begin : g_t
          wire signed [7:0] k0 = $signed(k_r[(gp*192+gh*64+2*gt)*8 +: 8]);
          wire signed [7:0] k1 = $signed(k_r[(gp*192+gh*64+2*gt+1)*8 +: 8]);
          wire signed [15:0] cc = cos_rom[gp*32+gt];
          wire signed [15:0] ss = sin_rom[gp*32+gt];
          wire signed [24:0] r0w = (k0*cc - k1*ss) >>> 12;
          wire signed [24:0] r1w = (k0*ss + k1*cc) >>> 12;
          wire [7:0] b0 = (r0w > 127) ? 8'd127 : ((r0w < -128) ? 8'd128 : r0w[7:0]);
          wire [7:0] b1 = (r1w > 127) ? 8'd127 : ((r1w < -128) ? 8'd128 : r1w[7:0]);
          assign k_rope[(gp*192+gh*64+2*gt)*8 +: 8] = b0;
          assign k_rope[(gp*192+gh*64+2*gt+1)*8 +: 8] = b1;
        end
      end
    end
  endgenerate

  // ---- QK chunk mux (chunk c = head c>>1, half c&1; GQA thirds) ----
  reg [255:0] qk_avec, qk_bvec;
  reg qk_ce;
  wire [31:0] qk_acc;
  wire [3:0] qh = qc[4:1];
  wire [1:0] qkh = (qh >= 6) ? 2 : ((qh >= 3) ? 1 : 0);
  always @(*) begin
    qk_avec = q_rope[(qi*576 + qh*64 + qc[0]*32)*8 +: 256];
    qk_bvec = k_rope[(qj*192 + qkh*64 + qc[0]*32)*8 +: 256];
  end
  mac_array #(.W(8), .P(32)) u_qk (
    .clk(clk), .rst_n(rst_n), .ce(qk_ce), .clr(1'b0),
    .avec(qk_avec), .bvec(qk_bvec), .acc_in(32'b0), .acc_out(qk_acc)
  );

  // ---- scale to Q4.12 scores (arith >>3, saturate) ----
  reg [S*16-1:0] scores_flat;
  reg sm_send;
  integer sj;
  always @(*) begin
    for (sj = 0; sj < S; sj = sj + 1) begin
      if ((l_raw[r][sj] >>> 3) > 32767)
        scores_flat[sj*16 +: 16] = 16'd32767;
      else if ((l_raw[r][sj] >>> 3) < -32768)
        scores_flat[sj*16 +: 16] = 16'h8000;
      else
        scores_flat[sj*16 +: 16] = (l_raw[r][sj] >>> 3);
    end
  end

  // ---- causal row-softmax (causal forced high; frame-start reset) ----
  wire sm_rst_n = rst_n & (state != RSTRM);
  wire [S*16-1:0] probs;
  wire sm_valid;
  softmax_d #(.W(16), .S(S)) u_softmax (
    .clk(clk), .rst_n(sm_rst_n), .scores(scores_flat),
    .scores_valid(sm_send), .causal(1'b1),
    .probs(probs), .probs_valid(sm_valid)
  );

  // ---- AV byte shots through the second mac (A = hi*256 + lo) ----
  wire signed [15:0] a_cur = a_buf[ai][aj];
  wire [7:0] a_lo = a_cur[7:0];
  wire [7:0] a_hi = a_cur[15:8];
  // GQA head-concat: the 192-wide (3x64) result fans out x3 to 576 wide.
  wire [1:0] kh2 = ad2[7:6];
  wire [5:0] din2 = ad2[5:0];
  wire signed [7:0] v_byte = $signed(v_r[(aj*192+ad2)*8 +: 8]);
  reg [255:0] av_avec, av_bvec;
  reg av_ce;
  wire [31:0] av_acc;
  always @(*) begin
    if (ap >= 3) begin
      av_avec = {{31{8'b0}}, a_hi};
      av_bvec = {{31{8'b0}}, v_byte};
    end else begin
      av_avec = {{31{8'b0}}, a_lo};
      av_bvec = {{31{8'b0}}, v_byte};
    end
  end
  mac_array #(.W(8), .P(32)) u_av (
    .clk(clk), .rst_n(rst_n), .ce(av_ce), .clr(1'b0),
    .avec(av_avec), .bvec(av_bvec), .acc_in(32'b0), .acc_out(av_acc)
  );

  // ---- staging SRAMs (written per frame; reads tied, monitored) ----
  wire [511:0] qbuf_r;
  wire [191:0] kbuf_r, vbuf_r, kc_r, vc_r;
  wire [15:0] score_r;
  reg [6:0] qb_wa, kb_wa;
  reg [11:0] sc_wa;
  reg [10:0] kc_wa;
  reg [511:0] qb_wd;
  reg [191:0] kb_wd;
  reg [15:0] sc_wd;
  reg qb_we, kb_we, vb_we, kc_we, vc_we, sc_we;
  sram_1r1w #(.W(512), .N(128)) u_qbuf (
    .clk(clk), .ra(7'd0), .wa(qb_wa), .wdata(qb_wd), .we(qb_we), .rdata(qbuf_r)
  );
  sram_1r1w #(.W(192), .N(128)) u_kbuf (
    .clk(clk), .ra(7'd0), .wa(kb_wa), .wdata(kb_wd), .we(kb_we), .rdata(kbuf_r)
  );
  sram_1r1w #(.W(192), .N(128)) u_vbuf (
    .clk(clk), .ra(7'd0), .wa(kb_wa), .wdata(kb_wd), .we(vb_we), .rdata(vbuf_r)
  );
  wire [11:0] kc_sum = cache_ptr + cr;
  sram_1r1w #(.W(192), .N(2048)) u_kcache (
    .clk(clk), .ra(11'd0), .wa(kc_sum[10:0]), .wdata(kb_wd),
    .we(kc_we), .rdata(kc_r)
  );
  sram_1r1w #(.W(192), .N(2048)) u_vcache (
    .clk(clk), .ra(11'd0), .wa(kc_sum[10:0]), .wdata(kb_wd),
    .we(vc_we), .rdata(vc_r)
  );
  sram_1r1w #(.W(16), .N(4096)) u_score (
    .clk(clk), .ra(12'd0), .wa(sc_wa), .wdata(sc_wd), .we(sc_we), .rdata(score_r)
  );
  wire [511:0] of_r;
  wire of_full, of_empty;
  reg [511:0] of_wd;
  reg of_wr, of_rd;
  fifo_sync #(.W(512), .D(4)) u_outfifo (
    .clk(clk), .rst_n(rst_n), .wdata(of_wd), .wr(of_wr),
    .rd(of_rd), .rdata(of_r), .full(of_full), .empty(of_empty)
  );

  assign qkv_ready = (state == IDLE);
  assign y_out = y_r;
  assign y_valid = yv_q;

  integer fj;
  // Correction for the mac's signed lane view: true unsigned lo product is
  // lo_s*v + 256*v when a_lo[7] is set. Signed mult (inferred *), NOT a
  // concat: {v_byte,8'b0} is unsigned and would zero-extend (+65536 error
  // for v < 0); $signed(v_byte)*256 sign-extends exactly.
  wire signed [31:0] av_corr = a_lo[7] ? ($signed(v_byte) * 256) : 32'sd0;
  wire signed [31:0] av_next = acc_av + tmp_lo + av_corr + ($signed(av_acc) <<< 8);
  wire signed [31:0] av_yw = (av_next + 2048) >>> 12;
  wire [7:0] av_yb = (av_yw > 127) ? 8'd127 : ((av_yw < -128) ? 8'd128 : av_yw[7:0]);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE; q_r <= 0; k_r <= 0; v_r <= 0; y_r <= 0;
      nrows <= 0; qi <= 0; qj <= 0; qc <= 0; qp <= 0; acc_qk <= 0;
      r <= 0; w <= 0; cr <= 0; ai <= 0; aj <= 0; ad2 <= 0; ap <= 0;
      acc_av <= 0; tmp_lo <= 0; wq <= 0; woc <= 0; yv_q <= 0;
      cache_ptr <= 0; qk_ce <= 0; av_ce <= 0; sm_send <= 0;
      qb_we <= 0; kb_we <= 0; vb_we <= 0; kc_we <= 0; vc_we <= 0; sc_we <= 0;
      of_wr <= 0; of_rd <= 0;
    end else begin
      qk_ce <= 0; av_ce <= 0; sm_send <= 0;
      qb_we <= 0; kb_we <= 0; vb_we <= 0; kc_we <= 0; vc_we <= 0; sc_we <= 0;
      of_wr <= 0; of_rd <= 0; yv_q <= 0;
      case (state)
        IDLE: if (qkv_valid) begin
          q_r <= q_in; k_r <= k_in; v_r <= v_in;
          nrows <= ((s_cfg == 0) || (s_cfg > S)) ? S7 : s_cfg;
          wq <= 0;
          state <= RSTRM;
        end
        RSTRM: begin // 1 cycle: softmax row_q -> 0 (frame-start reset)
          cr <= 0;
          state <= CACHEW;
        end
        CACHEW: begin // KV-cache prefill append + K/V staging + Y zero-fill
          if (cr < nrows) begin
            kb_wd <= k_r[(cr*192)*8 +: 192];
            kb_wa <= cr;
            kb_we <= 1; vb_we <= 1;
            kc_we <= 1; vc_we <= 1;
          end else begin
            y_r[(cr*576)*8 +: 576*8] <= 0;
          end
          if (cr == S-1) begin
            qi <= 0; qj <= 0; qc <= 0; qp <= 0; acc_qk <= 0;
            state <= QK;
          end else cr <= cr + 1'b1;
        end
        QK: begin // 18 single-shot chunks per (i,j) pair via u_qk
          if (wq < NWORDS_Q) begin
            qb_wd <= q_r[wq*512 +: 512];
            qb_wa <= wq[6:0];
            qb_we <= 1;
            wq <= wq + 1'b1;
          end
          if (qp == 0 || qp == 1) begin
            qk_ce <= 1; // hold ce through WAIT: acc_out settles for CAP
            qp <= qp + 1'b1;
          end else begin
            qp <= 0;
            if (qc == 17) begin
              qc <= 0;
              l_raw[qi][qj] <= acc_qk + $signed(qk_acc);
              acc_qk <= 0;
              if (qi == nrows-1 && qj == nrows-1) begin
                r <= 0;
                state <= SM_S;
              end else if (qj == nrows-1) begin
                qj <= 0; qi <= qi + 1'b1;
              end else qj <= qj + 1'b1;
            end else begin
              qc <= qc + 1'b1;
              acc_qk <= acc_qk + $signed(qk_acc);
            end
          end
        end
        SM_S: begin
          sm_send <= 1;
          state <= SM_R;
        end
        SM_R: if (sm_valid) begin
          for (fj = 0; fj < S; fj = fj + 1)
            a_buf[r][fj] <= $signed(probs[fj*16 +: 16]);
          w <= 0;
          state <= SM_W;
        end
        SM_W: begin // spill A row to score SRAM
          sc_wa <= r*S+w;
          sc_wd <= a_buf[r][w];
          sc_we <= 1;
          if (w == S-1) begin
            if (r == nrows-1) begin
              ai <= 0; ad2 <= 0; aj <= 0; ap <= 0; acc_av <= 0;
              state <= AV;
            end else begin
              r <= r + 1'b1;
              state <= SM_S;
            end
          end else w <= w + 1'b1;
        end
        AV: begin // scalar hi/lo byte shots per (i,vd,j) via u_av;
          // vd spans the 192 KV-wide columns; the GQA head-concat fans
          // each result byte out x3 to the 576-wide Y row below.
          if (ap == 0 || ap == 1 || ap == 3 || ap == 4) begin
            av_ce <= 1; // hold ce through WAIT: acc_out settles for CAP
            ap <= ap + 1'b1;
          end else if (ap == 2) begin
            tmp_lo <= $signed(av_acc);
            ap <= 3;
          end else begin // ap == 5 CAP_HI
            ap <= 0;
            if (aj == nrows-1) begin
              aj <= 0;
              y_r[(ai*576+(kh2*3)*64+din2)*8 +: 8] <= av_yb;
              y_r[(ai*576+(kh2*3+1)*64+din2)*8 +: 8] <= av_yb;
              y_r[(ai*576+(kh2*3+2)*64+din2)*8 +: 8] <= av_yb;
              acc_av <= 0;
              if (ad2 == KV-1) begin
                ad2 <= 0;
                if (ai == nrows-1) begin
                  woc <= 0;
                  state <= OUTF;
                end else ai <= ai + 1'b1;
              end else ad2 <= ad2 + 1'b1;
            end else begin
              aj <= aj + 1'b1;
              acc_av <= av_next;
            end
          end
        end
        OUTF: begin // stream Y frame words to the out FIFO (flow-through)
          of_wd <= y_r[woc*512 +: 512];
          of_wr <= 1; of_rd <= 1;
          if (woc == NWORDS_Q-1) state <= YV;
          else woc <= woc + 1'b1;
        end
        YV: begin
          yv_q <= 1;
          cache_ptr <= cache_ptr + nrows;
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
