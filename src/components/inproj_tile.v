// inproj_tile — L1 wiring + chunk-fold engine (02-inproj-tile.md).
//
// Parent I/O: tok[Sx576]s8 -> y_out[Sx960]s8 packed Q[576]+K[192]+V[192].
// Chunked (CHUNKS=C, CHUNK=k): y_out carries slice k only, Sx(Q_N+K_N+V_N)
// packed Q-slice,K-slice,V-slice; C slices concat thirds to rebuild mono.
// One tile time-muxes the 576-col input in C=256 chunks (2x256 + 64-tail);
// K/V thirds are the same pass, sliced per OLP lane for the ATTN handoff.
//
// Datapath (children are the frozen topology; this file adds the wiring and
// the inferred chunk-fold control — only +,-,*,if/case, no new modules):
//   tok -> u_infifo (4608b single-row skid) -> row latch
//        -> u_mac P=32 K-fold (18 passes of 32 over K=576) with acc_in fold
//           (hold_q feeds back; 32-bit wrap mod-2^32, never saturates here)
//        -> u_accum (960x32s, cleared per row) holds exact s32 psums
//        -> u_requant per output with (cfg_scale,cfg_zero): saturation lives
//           HERE only: y = clip_int8((acc*scale)>>8 + zero)
//        -> packed y_out thirds; u_outfifo carries the low 4096b slice as
//           the OLP skid; u_ctrl sequences chunks (its fifo_rd gates
//           tok_ready; phase/layer/cal/lane taps stay cabled for backend).
// No bias anywhere (MobileLLM dense mats ship none): accum feeds requant
// direct. Weights (compile-time USE_SRAM_W): 1 = wide SRAM banks bound
// via W*_WIDE_FILE (per-slice *_w32.hex; ST_RD primes each fold — the
// prelim-GDS path); 0 = host-pinned image fallback (WQ/WK/WV_FILE,
// repo-root-relative $readmemh).
// y_valid pulses exactly one cycle per packed frame (per packed row when S=1).
// Weight-path overrides: VERILOG_DEFINES (LibreLane) or -D (hand flow)
// injects an absolute path; defaults stay repo-root-relative for sim.
`ifndef IQ_WQ_PATH
`define IQ_WQ_PATH "weights/bake/layer0_q_proj.hex"
`endif
`ifndef IQ_WK_PATH
`define IQ_WK_PATH "weights/bake/layer0_k_proj.hex"
`endif
`ifndef IQ_WV_PATH
`define IQ_WV_PATH "weights/bake/layer0_v_proj.hex"
`endif
`ifndef IQ_WQW_PATH
`define IQ_WQW_PATH "weights/bake/layer0_q_proj_w32.hex"
`endif
`ifndef IQ_WKW_PATH
`define IQ_WKW_PATH "weights/bake/layer0_k_proj_w32.hex"
`endif
`ifndef IQ_WVW_PATH
`define IQ_WVW_PATH "weights/bake/layer0_v_proj_w32.hex"
`endif
module inproj_tile #(
  parameter S = 64,
  parameter H = 576,
  parameter KV = 192,
  parameter C = 256,
  // Row-slice chunking (parametric P&R sharding, build.sh --chunk):
  // CHUNKS = total slices over the packed output axis (must divide H and
  // KV so every third splits evenly), CHUNK = this slice 0..CHUNKS-1.
  // Slice k owns packed thirds Q[k*QN..]+K[k*KN..]+V[k*VN..]; the stitch
  // concatenates thirds across slices to rebuild the monolithic frame.
  // CHUNKS=1,CHUNK=0 reproduces the monolithic tile exactly (same ports,
  // same cycle behavior). y_out carries ONLY this slice's thirds, packed
  // Q-slice,K-slice,V-slice (LSB-first), S rows of NW bytes.
  parameter CHUNKS = 1,
  parameter CHUNK = 0,
  parameter WQ_FILE = `IQ_WQ_PATH,
  parameter WK_FILE = `IQ_WK_PATH,
  parameter WV_FILE = `IQ_WV_PATH,
  // Compile-time weight source: USE_SRAM_W=1 reads the wide SRAM banks
  // (per-slice *_w32.hex from chunk.py --wide / pack.py — the prelim-GDS
  // path); 0 uses the pinned images. ST_RD absorbs bank latency.
  parameter WQ_WIDE_FILE = `IQ_WQW_PATH,
  parameter WK_WIDE_FILE = `IQ_WKW_PATH,
  parameter WV_WIDE_FILE = `IQ_WVW_PATH,
  parameter USE_SRAM_W = 1,
  // Requant shift for the shared QKV scale point (calibration emits
  // per-layer (SC_QKVM, SC_QKVSH); default 8 keeps stitch behavior).
  parameter [4:0] QKV_SH = 5'd8
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [S*H*8-1:0]    tok_in,
  input  wire                tok_valid,
  input  wire [15:0]         cfg_scale, // per-chunk requant scale (Q8.8)
  input  wire [15:0]         cfg_zero,  // per-chunk requant zero
  output wire                tok_ready,
  output wire [S*(H/CHUNKS+2*(KV/CHUNKS))*8-1:0] y_out,
  output wire                y_valid
);
  localparam NO = H + 2*KV;          // 960 packed outputs per row (mono; NW when sliced)
  localparam Q_N = H / CHUNKS;       // slice rows: Q third
  localparam K_N = KV / CHUNKS;      // slice rows: K third
  localparam V_N = KV / CHUNKS;      // slice rows: V third
  localparam Q_LO = CHUNK * Q_N;     // global first row of this Q slice
  localparam K_LO = CHUNK * K_N;     // global first row of this K slice
  localparam V_LO = CHUNK * V_N;     // global first row of this V slice
  localparam NW = Q_N + K_N + V_N;   // packed slice outputs per row
  localparam NF = (H + 32 - 1) / 32; // 18 K-folds of P=32 over K=576
  localparam OUTF_W = (S*NW*8 >= 4096) ? 4096 : S*NW*8; // skid slice width

  // Divisibility contract (--chunk resolves C dividing H and KV; the
  // Python emitter enforces it, this fires in sim on hand misuse).
  initial begin
    if (H % CHUNKS != 0 || KV % CHUNKS != 0 || CHUNK >= CHUNKS) begin
      $error("inproj_tile: CHUNKS=%0d must divide H=%0d and KV=%0d, CHUNK=%0d < CHUNKS",
             CHUNKS, H, KV, CHUNK);
    end
  end

  // ---- pinned weight image (USE_SRAM_W=0 fallback, row-major) ----
  // Chunk files hold ONLY this slice's rows (see weights/bake/chunk.py);
  // the monolithic files are the CHUNKS=1 special case.
  reg [7:0] wq_img [0:Q_N*H-1];
  reg [7:0] wk_img [0:K_N*H-1];
  reg [7:0] wv_img [0:V_N*H-1];
  initial begin
    if (!USE_SRAM_W) begin
      $readmemh(WQ_FILE, wq_img);
      $readmemh(WK_FILE, wk_img);
      $readmemh(WV_FILE, wv_img);
    end
  end

  // Wide-bank geometry (banks instantiate after the j/f regs below —
  // iverilog needs declaration before use).
  localparam QW = Q_N * NF;
  localparam KW = K_N * NF;

  // ---- engine state ----
  localparam ST_IDLE = 4'd0, ST_POPW = 4'd1, ST_POPC = 4'd2,
             ST_MSET = 4'd3, ST_MCAP = 4'd4, ST_AWR = 4'd5,
             ST_RSET = 4'd6, ST_RSAMP = 4'd7, ST_RCAP = 4'd8,
             ST_DONE = 4'd9, ST_RD = 4'd10;
  reg [3:0] state_q;
  reg [7:0] row_q;    // token row 0..S-1
  reg [9:0] j_q;      // slice-local packed output 0..NW-1 (mono: 0..959)
  reg [4:0] f_q;      // K-fold 0..17
  reg [31:0] hold_q;  // acc_in fold register (wraps mod-2^32)
  reg [7:0] xbuf_q [0:S*H-1]; // latched frame rows
  reg [7:0] xrow_q [0:H-1];   // current row under the K-fold
  reg [S*NW*8-1:0] y_out_q;   // slice frame (mono: full 960-wide frame)
  reg y_valid_q;
  // mac ce/clr are COMBINATIONAL (not regs): the mac samples avec/bvec/
  // acc_in at posedges, so ce must be high DURING each MSET fold cycle and
  // clr during the single POPC/row-advance cycle that precedes the next
  // MSET. Registered versions arrive one cycle late, which silently drops
  // every odd K-fold (proven: accum held only even folds).
  // Row-advance clear: RCAP last-lane of a non-final row (S>1 path).
  wire mac_ce  = (state_q == ST_MSET);
  wire mac_clr = (state_q == ST_POPC) ||
                 (state_q == ST_RCAP && j_q == NW-1 && row_q != S-1);
  // Index regs stay 10-bit (j_q domain); the slice-narrowed regfile
  // drops high zero bits at the instance below (j_q < NW by construction).
  reg [9:0] acc_ra_q, acc_wa_q;
  reg [31:0] acc_wdata_q;
  reg acc_we_q;
  reg inf_wr_q, inf_rd_q, out_wr_q;
  reg [255:0] mac_avec_q, mac_bvec_q; // K-fold lane mux (drives u_mac)
  reg [7:0] wb; // weight byte select

  assign y_out = y_out_q;
  assign y_valid = y_valid_q;

  // ---- child interconnect ----
  wire [4607:0] inf_rdata;
  wire inf_full, inf_empty;
  wire [31:0] mac_psum;
  wire [31:0] acc_rda, acc_rdb;
  wire [7:0] req_byte;
  wire req_valid_unused;
  wire [OUTF_W-1:0] out_rdata;
  wire out_full, out_empty;
  wire [3:0] phase_unused;
  wire [4:0] layer_unused;
  wire [22:0] cal_unused;
  wire [5:0] ilp_unused, olp_unused, ctrl_rd_w;
  wire ctrl_done_unused;

  fifo_sync #(.W(4608), .D(8)) u_infifo (
    .clk(clk), .rst_n(rst_n),
    .wdata(tok_in[4607:0]), .wr(inf_wr_q),
    .rd(inf_rd_q), .rdata(inf_rdata),
    .full(inf_full), .empty(inf_empty)
  );
  mac_array #(.W(8), .P(32)) u_mac (
    .clk(clk), .rst_n(rst_n), .ce(mac_ce), .clr(mac_clr),
    .avec(mac_avec_q), .bvec(mac_bvec_q), .acc_in(hold_q),
    .acc_out(mac_psum)
  );
  /* verilator lint_off WIDTHTRUNC */
  regfile_dp #(.W(32), .N(NW)) u_accum (
    .clk(clk), .ra(acc_ra_q), .rb(10'd0),
    .wa(acc_wa_q), .wdata(acc_wdata_q), .we(acc_we_q),
    .rda(acc_rda), .rdb(acc_rdb)
  );
  /* verilator lint_on WIDTHTRUNC */
  // No bias: psum flows direct into requant; saturation lives here only.
  requant #(.W(8), .SHIFT(QKV_SH)) u_requant (
    .clk(clk), .rst_n(rst_n), .acc_wide(acc_rda),
    .scale(cfg_scale), .zero(cfg_zero),
    .act_int(req_byte), .valid(req_valid_unused)
  );
  fifo_sync #(.W(OUTF_W), .D(8)) u_outfifo (
    .clk(clk), .rst_n(rst_n),
    .wdata(y_out_q[OUTF_W-1:0]), .wr(out_wr_q),
    .rd(1'b0), .rdata(out_rdata), .full(out_full), .empty(out_empty)
  );
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(tok_valid),
    .prefill(1'b1),
    .irq_tile_done(y_valid_q), .irq_frame_done(1'b0),
    .phase_sel(phase_unused), .layer_idx(layer_unused),
    .cal_addr(cal_unused),
    .fifo_lane_en_ilp(ilp_unused), .fifo_lane_en_olp(olp_unused),
    .fifo_rd(ctrl_rd_w[0]), .layer_done(ctrl_done_unused)
  );
  assign ctrl_rd_w[5:1] = 5'b0;
  assign tok_ready = ctrl_rd_w[0] & (state_q == ST_IDLE);

  // ---- wide weight banks (USE_SRAM_W=1): 32B rows, one per (output,fold)
  // Bank row for slice-local output j, fold f: Q j*NF+f over Q_N rows,
  // K/V (j-Q_N/-K_N)*NF+f. Bank files hold this slice's rows, wide-packed
  // (pack.py lane order: table byte 0 at the line LSB).
  wire [$clog2(QW)-1:0] wra_q = j_q * NF + f_q;
  wire [$clog2(KW)-1:0] wra_k = (j_q - Q_N) * NF + f_q;
  wire [$clog2(KW)-1:0] wra_v = (j_q - Q_N - K_N) * NF + f_q;
  wire [255:0] wrow_q, wrow_k, wrow_v;
  sram_1r1w #(.W(256), .N(QW), .INIT_FILE(WQ_WIDE_FILE)) u_wqbank (
    .clk(clk), .ra(wra_q), .wa({$clog2(QW){1'b0}}), .wdata(256'b0),
    .we(1'b0), .rdata(wrow_q)
  );
  sram_1r1w #(.W(256), .N(KW), .INIT_FILE(WK_WIDE_FILE)) u_wkbank (
    .clk(clk), .ra(wra_k), .wa({$clog2(KW){1'b0}}), .wdata(256'b0),
    .we(1'b0), .rdata(wrow_k)
  );
  sram_1r1w #(.W(256), .N(KW), .INIT_FILE(WV_WIDE_FILE)) u_wvbank (
    .clk(clk), .ra(wra_v), .wa({$clog2(KW){1'b0}}), .wdata(256'b0),
    .we(1'b0), .rdata(wrow_v)
  );

  // ---- K-fold lane mux (inferred if/case over the stationary weights)
  // j_q is slice-local: [0,Q_N) hits Q, [Q_N,Q_N+K_N) hits K, the rest V.
  // Bank path reads the wide-bank row (1-cycle latency, absorbed by
  // ST_RD); image path reads the slice image combinationally.
  integer p;
  always @(*) begin
    mac_avec_q = 256'b0;
    mac_bvec_q = 256'b0;
    for (p = 0; p < 32; p = p + 1) begin
      mac_avec_q[p*8 +: 8] = xrow_q[f_q*32+p];
      if (j_q < Q_N)
        wb = USE_SRAM_W ? wrow_q[p*8 +: 8] : wq_img[j_q*H+f_q*32+p];
      else if (j_q < Q_N+K_N)
        wb = USE_SRAM_W ? wrow_k[p*8 +: 8] : wk_img[(j_q-Q_N)*H+f_q*32+p];
      else
        wb = USE_SRAM_W ? wrow_v[p*8 +: 8] : wv_img[(j_q-Q_N-K_N)*H+f_q*32+p];
      mac_bvec_q[p*8 +: 8] = wb;
    end
  end

  // ---- chunk-fold sequencer ----
  integer b, r;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      row_q <= 8'd0; j_q <= 10'd0; f_q <= 5'd0;
      hold_q <= 32'd0;
      y_out_q <= {S*NW*8{1'b0}};
      y_valid_q <= 1'b0;
      acc_ra_q <= 10'd0; acc_wa_q <= 10'd0;
      acc_wdata_q <= 32'd0; acc_we_q <= 1'b0;
      inf_wr_q <= 1'b0; inf_rd_q <= 1'b0; out_wr_q <= 1'b0;
    end else begin
      acc_we_q <= 1'b0;
      inf_wr_q <= 1'b0; inf_rd_q <= 1'b0; out_wr_q <= 1'b0;
      y_valid_q <= 1'b0;
      case (state_q)
        ST_IDLE: begin
          if (tok_valid) begin
            inf_wr_q <= 1'b1; // skid the first row slice
            row_q <= 8'd0;
            state_q <= ST_POPW;
          end
        end
        // POPW: the IDLE-issued push lands in u_infifo at this edge; raise
        // rd so the FWFT head (our row) is stable through the next cycle.
        ST_POPW: begin
          inf_rd_q <= 1'b1;
          state_q <= ST_POPC;
        end
        // POPC: capture the skid head (row 0) + tok_in rows; the pop takes
        // effect at this edge, so pre-edge rdata is still our row.
        ST_POPC: begin
          hold_q <= 32'd0; j_q <= 10'd0; f_q <= 5'd0;
          for (b = 0; b < H; b = b + 1)
            xrow_q[b] <= inf_rdata[b*8 +: 8];
          for (r = 0; r < S; r = r + 1)
            for (b = 0; b < H; b = b + 1)
              xbuf_q[r*H+b] <= (r == 0)
                ? inf_rdata[b*8 +: 8]
                : tok_in[(r*H+b)*8 +: 8];
          state_q <= ST_RD;
        end
        // RD: bank-read prime — ra (from the incoming j/f) settles and the
        // bank row lands on rdata while the MAC holds (ce stays 0). The
        // image path ignores this cycle. Every road into MSET goes via RD.
        ST_RD: begin
          state_q <= ST_MSET;
        end
        ST_MSET: begin
          // mac samples avec/bvec/acc_in=hold at the MSET->MCAP edge;
          // ce is combinational (high throughout MSET), clr in POPC.
          state_q <= ST_MCAP;
        end
        ST_MCAP: begin
          hold_q <= mac_psum; // fold captured (mod-2^32, no saturation)
          if (f_q == NF-1)
            state_q <= ST_AWR;
          else begin
            f_q <= f_q + 5'd1;
            state_q <= ST_RD;
          end
        end
        ST_AWR: begin
          acc_wa_q <= j_q; acc_wdata_q <= hold_q; acc_we_q <= 1'b1;
          hold_q <= 32'd0; // fresh fold chain for the next output
          f_q <= 5'd0;
          if (j_q == NW-1) begin
            j_q <= 10'd0;
            state_q <= ST_RSET;
          end else begin
            j_q <= j_q + 10'd1;
            state_q <= ST_RD;
          end
        end
        ST_RSET: begin
          acc_ra_q <= j_q; // rda settles combinationally into requant
          state_q <= ST_RSAMP;
        end
        ST_RSAMP: begin
          state_q <= ST_RCAP; // requant samples acc at this edge
        end
        ST_RCAP: begin
          y_out_q[(row_q*NW+j_q)*8 +: 8] <= req_byte; // packed thirds byte
          if (j_q == NW-1) begin
            if (row_q == S-1) begin
              state_q <= ST_DONE;
            end else begin
              row_q <= row_q + 8'd1;
              for (b = 0; b < H; b = b + 1)
                xrow_q[b] <= xbuf_q[(row_q+1)*H+b];
              hold_q <= 32'd0; j_q <= 10'd0; f_q <= 5'd0;
              state_q <= ST_RD;
            end
          end else begin
            j_q <= j_q + 10'd1;
            state_q <= ST_RSET;
          end
        end
        ST_DONE: begin
          y_valid_q <= 1'b1; // exactly one cycle per packed frame
          out_wr_q <= 1'b1;
          state_q <= ST_IDLE;
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end
endmodule
