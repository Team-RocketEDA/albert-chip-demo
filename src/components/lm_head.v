// lm_head — L1 stitch (wired logic).
// Contract: architecture/blocks/07-lm-head.md (MobileLLM last-token LM
// head). Parent I/O: x = X_last[576] s8 -> logits = x*W_lm^T (32000
// classes) -> pred token id (argmax). Dtypes: INT8 weights (Q1.7), INT16
// acts, INT32 accum, INT16 logits; host quantizes from HF golden. W_lm/B_lm
// sharing with the embed table is ASSUMED tied per the model card (§9
// reverify: one shared 18MB bank vs two).
//
// Top ports: x_last_in (576 s8, parent pre-slices X_29 last row),
// x_valid (1b strobe); pred_out (15b id); done (1b, single-cycle pulse).
//
// Datapath (iverilog subset): LAST_BUF latch (x_valid -> xbuf) -> inferred
// dots over the baked 16-row vocab subset (tv_lmhead_*, seed 0xB0C8; W image
// is the baked embed copy: wmem holds rows 0..15 of embed_full ==
// embed_proxy64 head via src/tb/lm_head_stitch/wlm_subset16.hex) -> inferred
// argmax compare loop (first-max wins) -> pred_out + single-cycle done.
// Full 32k x 576 is the Verilator stretch (time-muxed over u_lmmac 32-lane
// MAC + u_wlm bank), NOT iverilog serial.
// Control: IDLE -> CALC (16 cycles, one row dot per cycle) -> AMAX (1 cycle
// compare) -> DONEP (done=1 for exactly one cycle) -> IDLE. done pulses
// exactly once per x_valid; x_valid while busy is ignored (single-frame
// tb protocol; loop_done gates x_valid at the top).
// Inferred +,-,* and if/case only; no single-operator modules. Children
// stay instantiated (ports/topology contract): u_lastbuf (double-buffer
// companion), u_wlm (stationary 32k bank placeholder), u_lmmac (32-lane
// companion for the Verilator full-vocab path), u_predfifo (buffers pred
// ids to the SW GenEval sink), u_ctrl (status sequencer; done is driven by
// the inferred FSM, not layer_done).
// Weight-path override: VERILOG_DEFINES (LibreLane) or -D (hand flow)
// injects an absolute path; default stays repo-root-relative for sim.
`ifndef LM_WLM_PATH
`define LM_WLM_PATH "src/tb/lm_head_stitch/wlm_subset16.hex"
`endif
module lm_head #(
  parameter H = 576,
  parameter V = 32000,
  // Full-vocab codec path: VROWS=32000 binds the tied embed table
  // (WLM_FILE=embed_full.hex) for a TRUE argmax; 16 keeps the subset
  // stitch golden.
  parameter VROWS = 16,
  parameter WLM_FILE = `LM_WLM_PATH
)(
  input  wire          clk,
  input  wire          rst_n,
  input  wire [H*8-1:0] x_last_in, // last-token vector (parent slices X[SxH])
  input  wire          x_valid,
  output wire [14:0]   pred_out,   // predicted token id (< 2^15)
  output wire          done
);

  localparam [1:0] ST_IDLE = 2'd0,
                   ST_CALC = 2'd1,
                   ST_AMAX = 2'd2,
                   ST_DONE = 2'd3;

  reg [1:0] state;
  reg [7:0]  xbuf [0:H-1];          // LAST_BUF latched last-token row (s8)
  localparam RW = (VROWS > 1) ? $clog2(VROWS) : 1;
  reg [7:0]  wmem [0:VROWS*H-1];    // W_lm rows (s8, stationary)
  reg [31:0] logits [0:VROWS-1];    // logits (s32, exact mod-2^32)
  reg [14:0] pred_r;
  reg        done_r;

  assign pred_out = pred_r;
  assign done     = done_r;

  initial begin
    $readmemh(WLM_FILE, wmem);
  end

  reg signed [63:0] psum_tmp;
  integer p, k;
  reg [RW-1:0] best;
  reg [RW-1:0] row;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state  <= ST_IDLE;
      row    <= {RW{1'b0}};
      pred_r <= 15'd0;
      done_r <= 1'b0;
    end else begin
      case (state)
        ST_IDLE: begin
          done_r <= 1'b0;
          if (x_valid) begin
            for (p = 0; p < H; p = p + 1)
              xbuf[p] <= x_last_in[p*8 +: 8];
            row   <= {RW{1'b0}};
            state <= ST_CALC;
          end
        end
        ST_CALC: begin
          psum_tmp = 64'sd0;
          for (p = 0; p < H; p = p + 1)
            psum_tmp = psum_tmp + $signed(xbuf[p]) * $signed(wmem[row*H+p]);
          logits[row] <= psum_tmp[31:0];
          if (row == VROWS-1)
            state <= ST_AMAX;
          else
            row <= row + 1;
        end
        ST_AMAX: begin
          best = {RW{1'b0}};
          for (k = 1; k < VROWS; k = k + 1)
            if ($signed(logits[k]) > $signed(logits[best]))
              best = k[RW-1:0];
          pred_r <= {{15-RW{1'b0}}, best};
          state  <= ST_DONE;
        end
        ST_DONE: begin
          done_r <= 1'b1;
          state  <= ST_IDLE;
        end
        default: begin
          state  <= ST_IDLE;
          done_r <= 1'b0;
        end
      endcase
      // Single-cycle done: ST_DONE raises done_r for one cycle, IDLE
      // clears it. Back-to-back x_valid arrives only after the pulse
      // (the top gates x_valid with loop_done), so no queue is needed.
    end
  end

  // ---- structural children (topology contract; single-driver safe) ----
  // LAST_BUF double-buffer companion: parent slice enters both the inferred
  // xbuf latch and this skid; pop on latch.
  wire        lb_full, lb_empty;
  wire [H*8-1:0] lb_rdata;
  wire        lb_rd;
  assign lb_rd = (state == ST_IDLE) && x_valid;
  fifo_sync #(.W(4608), .D(4)) u_lastbuf (
    .clk(clk), .rst_n(rst_n), .wdata(x_last_in), .wr(x_valid),
    .rd(lb_rd), .rdata(lb_rdata), .full(lb_full), .empty(lb_empty)
  );
  // WLM stationary bank placeholder (full 32k rows; host-written once, no
  // write port during inference). The iverilog subset wmem above is rows
  // 0..15 of this bank's baked embed-copy image.
  wire [4607:0] wlm_rdata;
  sram_1r1w #(.W(4608), .N(32768)) u_wlm (
    .clk(clk), .ra(15'b0), .wa(15'b0), .wdata(4608'b0), .we(1'b0), .rdata(wlm_rdata)
  ); // W_lm rows [Vx576]s8 stationary; 32000 of 32768 rows used
  // LM_MAC 32-lane companion for the Verilator full-vocab time-mux path
  // (576/32 = 18 passes per class row, 32000 rows sequenced by the head
  // FSM). Idle in the iverilog subset run; subset dots above are inferred.
  wire [31:0] lm_psum;
  mac_array #(.W(8), .P(32)) u_lmmac (
    .clk(clk), .rst_n(rst_n), .ce(1'b0), .clr(1'b0),
    .avec(256'b0), .bvec(256'b0), .acc_in(32'b0), .acc_out(lm_psum)
  );
  // PRED_FIFO: buffers pred ids (128 x 15b) to the SW GenEval sink.
  wire [14:0] pf_rdata;
  wire        pf_full, pf_empty;
  fifo_sync #(.W(15), .D(128)) u_predfifo (
    .clk(clk), .rst_n(rst_n), .wdata(pred_r), .wr(done_r),
    .rd(1'b0), .rdata(pf_rdata), .full(pf_full), .empty(pf_empty)
  );
  // Status sequencer companion (does NOT drive done; done is the inferred
  // FSM pulse above).
  wire [3:0]  c_phase;
  wire [4:0]  c_layer;
  wire [22:0] c_addr;
  wire [5:0]  c_ilp, c_olp;
  wire        c_fifo_rd, c_done;
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(x_valid),
    .prefill(1'b1),
    .irq_tile_done(done_r), .irq_frame_done(1'b0),
    .phase_sel(c_phase), .layer_idx(c_layer), .cal_addr(c_addr),
    .fifo_lane_en_ilp(c_ilp), .fifo_lane_en_olp(c_olp),
    .fifo_rd(c_fifo_rd), .layer_done(c_done)
  );

endmodule
