// rmsnorm_stage — L1 stitch (wired logic).
// Contract: architecture/blocks/05-rmsnorm.md. Parent I/O: x[Sx576] s8 +
// resid[Sx576] s8 -> y[Sx576] FXP16 (Q8.8), S=64 rows = 64 frames.
// Datapath per stage: s8 entry widen s8<<8 exact (PARAMS boundary rule);
// resid saturate-to-s8 then <<8; rmsnorm_d (D=576) framed streaming;
// FXP16 lanes assembled into the y_out frame + TBUF store; exit requant
// (gain 1/256: scale=0x0001, SHIFT=8) narrows each lane to int8 in
// yq_mem for re-entry.
// y_valid strobes once per completed row (64 strobes per frame).
// Control: run latch holds u_norm in reset until in_valid; per-row
// LEAD(1, next lane0, = the OUT->LOAD edge cycle that samples nothing)
// + LOAD(576 lanes row0 / 575 lanes later rows) + WAIT(6: CALC+4NR+DEN)
// + OUT(576 collect). Counters mirror the rmsnorm_d frame exactly
// (frame period 2*D+6); back-to-back rows with no idle.
// Gamma weight-stationary: gmem loaded once from GN_FILE (Q8.8; the
// default is the stitch golden, the etched parent binds per-layer baked
// norms from emit_norms.py), never moves.
// Inferred +,-,* and if/case only; no single-operator modules.
// Weight-path override: VERILOG_DEFINES (LibreLane) or -D (hand flow)
// injects an absolute path; default stays repo-root-relative for sim.
`ifndef RN_GN_PATH
`define RN_GN_PATH "src/tb/rmsnorm_stage_stitch/gamma_q88.hex"
`endif
module rmsnorm_stage #(
  parameter S = 64,
  parameter H = 576,
  // Baked gamma binding (etched path): Q8.8 table, one s16 lane per col
  // (see weights/bake/emit_norms.py). Default keeps the stitch golden.
  parameter GN_FILE = `RN_GN_PATH,
  // Exit-requant gain select: yq = clip((y*1) >>> YQ_SHIFT). Default 8
  // keeps the integer-part (x1.0 scale) stitch behavior; etched layers
  // use 4 (x16 scale, 4 fractional bits, codes ~+/-96 for typical
  // normalized magnitudes). Calibration absorbs the scale uniformly.
  parameter [4:0] YQ_SHIFT = 5'd8
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire [S*H*8-1:0] x_in, // int8 entry; s8<<8 widen inside (doc 05)
  input  wire [S*H*8-1:0] resid_in, // int8 entry; saturate-then-<<8 (doc 05)
  input  wire              in_valid,
  output wire              in_ready,
  output wire [S*H*16-1:0] y_out,
  output wire              y_valid,
  // Etched re-entry path (ln1/ln2 width fix): the exit-requant int8
  // frame, valid sticky from frame-done until the next frame starts.
  output wire [S*H*8-1:0] yq_out,
  output wire              yq_valid
);
  localparam N = S * H;
  localparam [2:0] ST_IDLE = 3'd0,
                   ST_LEAD = 3'd1,
                   ST_LOAD = 3'd2,
                   ST_WAIT = 3'd3,
                   ST_OUT  = 3'd4,
                   ST_DONE = 3'd5;

  reg [2:0] state;
  reg [6:0] row;   // 0..S-1 (S=64)
  reg [9:0] col;   // 0..H-1 (H=576)
  reg [2:0] wcnt;  // WAIT 6-cycle count
  reg       run;   // holds u_norm in reset until arming in_valid

  reg signed [15:0] gmem [0:H-1];     // weight-stationary gamma (Q8.8)
  reg [7:0]  yq_mem [0:N-1];          // exit-requant int8 frame
  reg [S*H*16-1:0] y_packed;          // FXP16 out frame (clocked pack)

  initial begin
    $readmemh(GN_FILE, gmem);
  end

  // yq_out mirrors the exit-requant frame (combinational pack of yq_mem,
  // same style as the ffn y_out pack). yq_valid goes sticky at ST_DONE
  // and clears when the next frame arms, so the parent can consume the
  // frame after done without catching a 1-cycle strobe.
  genvar gq;
  generate
    for (gq = 0; gq < S*H; gq = gq + 1) begin : g_yqo
      assign yq_out[gq*8 +: 8] = yq_mem[gq];
    end
  endgenerate
  reg yq_valid_q;
  assign yq_valid = yq_valid_q;

  // ---- lane mux (combinational; LEAD pre-drives next row lane0) ----
  // lead_row tracks the row being started: row reg still holds the
  // just-finished row on OUT->LEAD; row 0 comes from IDLE->LEAD.
  reg [6:0] lead_row;
  wire [6:0] use_row = (state == ST_LEAD) ? lead_row :
                       (state == ST_IDLE) ? 7'd0 : row;
  wire [9:0] use_col = (state == ST_LEAD || state == ST_IDLE) ? 10'd0 : col;

  wire [7:0] x_byte = x_in[(use_row*H+use_col)*8 +: 8];
  wire [7:0] r_byte = resid_in[(use_row*H+use_col)*8 +: 8];

  // s8<<8 exact widen (trap: s8<<8 domain at the norm input).
  wire signed [15:0] x_w = {x_byte, 8'b0};
  // Resid saturate-to-s8 then <<8 (explicit clip; identity for s8 inputs,
  // documents the trap and guards any wider future feed).
  wire signed [8:0]  r_ext = {{1{r_byte[7]}}, r_byte};
  wire signed [7:0]  r_sat = (r_ext > 9'sd127) ? 8'sd127 :
                             (r_ext < -9'sd128) ? -8'sd128 : r_ext[7:0];
  wire signed [15:0] r_w = {r_sat, 8'b0};
  wire signed [15:0] g_w = (state == ST_IDLE) ? gmem[0] : gmem[use_col];

  wire        norm_rst_n = rst_n & run;
  wire [15:0] norm_y;
  wire        norm_yv;

  rmsnorm_d #(.W(16), .D(576)) u_norm (
    .clk(clk), .rst_n(norm_rst_n), .x(x_w), .resid(r_w),
    .gamma(g_w), .y(norm_y), .y_valid(norm_yv)
  );

  // Exit requant: FXP16 (Q8.8 lanes) -> int8 narrow for re-entry.
  // Default YQ_SHIFT=8: gain 1/256, clip(y>>>8) = lane integer part.
  // scale=0x0100 would be gain x1.0 (identity+clip), wrong domain for
  // Q8.8 lanes. YQ_SHIFT=4 keeps 4 fractional bits (x16 domain).
  wire [7:0] rq_byte;
  wire       rq_valid;
  requant #(.W(8), .SHIFT(YQ_SHIFT)) u_rq (
    .clk(clk), .rst_n(rst_n),
    .acc_wide({{16{norm_y[15]}}, norm_y}),
    .scale(16'h0001), .zero(16'h0000),
    .act_int(rq_byte), .valid(rq_valid)
  );

  // TBUF: 2 banks x S*D x16b frame store (linear row-major writes).
  wire [16:0] tbuf_wa = row * H + col;
  wire [15:0] tbuf_rd;
  sram_1r1w #(.W(16), .N(73728)) u_tbuf (
    .clk(clk), .ra(17'd0), .wa(tbuf_wa), .wdata(norm_y),
    .we(state == ST_OUT), .rdata(tbuf_rd)
  );

  // Status sequencer (row/tile/frame IRQs mirror the data FSM).
  wire [3:0]  c_phase;
  wire [4:0]  c_layer;
  wire [22:0] c_addr;
  wire [5:0]  c_ilp, c_olp;
  wire        c_fifo_rd, c_done;
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n),
    .irq_row_done(state == ST_LOAD),
    .irq_tile_done(y_valid),
    .irq_frame_done(state == ST_DONE),
    .prefill(1'b1),
    .phase_sel(c_phase), .layer_idx(c_layer), .cal_addr(c_addr),
    .fifo_lane_en_ilp(c_ilp), .fifo_lane_en_olp(c_olp),
    .fifo_rd(c_fifo_rd), .layer_done(c_done)
  );

  assign in_ready = (state == ST_IDLE);
  assign y_valid  = (state == ST_OUT && col == H-1);

  // y_out frame pack: clocked slice writes (no 36k combinational loop).
  assign y_out = y_packed;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= ST_IDLE;
      row      <= 7'd0;
      col      <= 10'd0;
      wcnt     <= 3'd0;
      run      <= 1'b0;
      lead_row <= 7'd0;
      yq_valid_q <= 1'b0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (in_valid) begin
            run      <= 1'b1;
            lead_row <= 7'd0;
            yq_valid_q <= 1'b0;
            state    <= ST_LEAD;
          end
        end
        ST_LEAD: begin
          // Next LOAD starts at lane 1, except row 0 which starts at 0
          // (first frame pays the reset-release edge: LEAD+LOAD[0..575];
          // later rows: LEAD=OUT->LOAD edge cycle, LOAD[1..575]).
          col   <= (lead_row == 7'd0) ? 10'd0 : 10'd1;
          row   <= lead_row;
          state <= ST_LOAD;
        end
        ST_LOAD: begin
          if (col == H-1) begin
            wcnt  <= 3'd0;
            state <= ST_WAIT;
          end else begin
            col <= col + 10'd1;
          end
        end
        ST_WAIT: begin
          if (wcnt == 3'd5) begin
            col   <= 10'd0;
            state <= ST_OUT;
          end else begin
            wcnt <= wcnt + 3'd1;
          end
        end
        ST_OUT: begin
          y_packed[(row*H+col)*16 +: 16] <= norm_y;
          if (col != 10'd0)
            yq_mem[row*H+col-1] <= rq_byte; // 1-cycle requant delay
          if (col == H-1) begin
            if (row == S-1) begin
              state <= ST_DONE;
            end else begin
              lead_row <= row + 7'd1;
              state    <= ST_LEAD;
            end
          end else begin
            col <= col + 10'd1;
          end
        end
        ST_DONE: begin
          yq_mem[row*H+(H-1)] <= rq_byte; // last lane clears requant pipe
          run   <= 1'b0;
          row   <= 7'd0;
          col   <= 10'd0;
          yq_valid_q <= 1'b1;
          state <= ST_IDLE;
        end
        default: begin
          state <= ST_IDLE;
        end
      endcase
      // TAIL-equivalent capture: the cycle after any OUT burst (LEAD of
      // the next row, or DONE of the last) holds R(lane575) at rq_byte.
      if (state == ST_LEAD)
        yq_mem[row*H+(H-1)] <= rq_byte;
    end
  end
endmodule
