// pooler_cls_head — L1 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM last-token LM head. x = X_last[576]s8 ->
// logits = x*W_lm^T (32000 classes) -> pred token id.
module pooler_cls_head #(
  parameter S = 64,
  parameter H = 576,
  parameter V = 32000
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire [S*H*16-1:0] tok_stream_in, // last token selected at implementation
  input  wire              seq_start,
  output wire [15:0]       margin_out,
  output wire [14:0]       pred_out,   // predicted token id (< 2^15)
  output wire [31:0]      correct_out, // scoreboard (driven at impl)
  output wire [31:0]      total_out,   // scoreboard (driven at impl)
  output wire              done
);
  wire [H*8-1:0] last_tok;
  wire [31:0]    lm_psum;

  fifo_sync #(.W(1024), .D(64)) u_tokfifo (
    .clk(clk), .rst_n(rst_n), .wdata(), .wr(seq_start),
    .rd(), .rdata(), .full(), .empty()
  );
  muxN #(.W(8), .N(2)) u_lastmux (
    .sel(1'b0), .din(16'b0), .dout()
  ); // last-token select (if/else at implementation)
  sram_1r1w #(.W(8), .N(32768)) u_lmw (
    .clk(clk), .ra(), .wa(), .wdata(8'b0), .we(1'b0), .rdata()
  );
  mac_array #(.W(8), .P(32)) u_lmmac (
    .clk(clk), .rst_n(rst_n), .ce(seq_start), .clr(1'b0),
    .avec(), .bvec(), .acc_in(32'b0), .acc_out(lm_psum)
  );
  cmp #(.W(16)) u_argmax (
    .a(16'b0), .b(16'b0), .y(), .gt(pred_out[0])
  );
  fifo_sync #(.W(15), .D(128)) u_score (
    .clk(clk), .rst_n(rst_n), .wdata(pred_out), .wr(done),
    .rd(), .rdata(), .full(), .empty()
  );

  // logits (32k x16) stream out of u_lmmac at implementation; margin/pred
  // upper bits + correct/total driven there too.
endmodule
