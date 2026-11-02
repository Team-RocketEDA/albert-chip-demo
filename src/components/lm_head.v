// lm_head — L1 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM last-token LM head. x = X_last[576]s8 ->
// logits = x*W_lm^T (32000 classes) -> pred token id (argmax).
// No CLS pooler, no tanh, no scoreboard: gen-subset compare lives in SW.
module lm_head #(
  parameter H = 576,
  parameter V = 32000
)(
  input  wire          clk,
  input  wire          rst_n,
  input  wire [H*8-1:0] x_last_in, // last-token vector (parent slices X[SxH])
  input  wire          x_valid,
  output wire [14:0]   pred_out,   // predicted token id (< 2^15)
  output wire          done
);
  wire [31:0] lm_psum;
  wire        row_done;

  fifo_sync #(.W(4608), .D(4)) u_lastbuf (
    .clk(clk), .rst_n(rst_n), .wdata(x_last_in), .wr(x_valid),
    .rd(), .rdata(), .full(), .empty()
  );
  sram_1r1w #(.W(4608), .N(32768)) u_wlm (
    .clk(clk), .ra(15'b0), .wa(15'b0), .wdata(4608'b0), .we(1'b0), .rdata()
  ); // W_lm rows [Vx576]s8 stationary; 32000 of 32768 rows used
  mac_array #(.W(8), .P(32)) u_lmmac (
    .clk(clk), .rst_n(rst_n), .ce(x_valid), .clr(1'b0),
    .avec(), .bvec(), .acc_in(32'b0), .acc_out(lm_psum)
  );
  cmp #(.W(16)) u_argmax (
    .a(16'b0), .b(16'b0), .y(), .gt(pred_out[0])
  ); // argmax over 32k logits at implementation; winning id -> pred_out
  fifo_sync #(.W(15), .D(128)) u_predfifo (
    .clk(clk), .rst_n(rst_n), .wdata(pred_out), .wr(done),
    .rd(), .rdata(), .full(), .empty()
  );
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(x_valid),
    .prefill(1'b1),
    .irq_tile_done(row_done), .irq_frame_done(1'b0),
    .phase_sel(), .layer_idx(), .cal_addr(),
    .fifo_lane_en_ilp(), .fifo_lane_en_olp(),
    .fifo_rd(), .layer_done(done)
  );

  // lm_psum/row_done converge at implementation (single net).
endmodule
