// albert_top — L0 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM decoder (retargeted; file names kept until repo rename).
// ids[S] -> EMBED -> LOOP 30x -> LM HEAD -> token id.
module albert_top #(
  parameter S = 64,
  parameter H = 576
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             start,
  input  wire [S*16-1:0]  ids_in,
  input  wire             ids_valid,
  output wire [14:0]      pred_out, // predicted token id
  output wire             done
);
  wire [S*H*8-1:0] x0;
  wire             x0_valid;
  wire [S*H*8-1:0] x12;
  wire [S*H*16-1:0] x12q; // s8 -> Q8.8 widening wired at implementation
  wire             x12_valid;
  wire [4:0]       layer_idx;
  wire             loop_done;

  embed_top #(.S(S), .H(H)) u_embed (
    .clk(clk), .rst_n(rst_n), .ids_in(ids_in), .ids_valid(ids_valid),
    .ids_ready(), .x0_out(x0), .x0_valid(x0_valid)
  );
  loop_mem_seq #(.S(S), .H(H)) u_loop (
    .clk(clk), .rst_n(rst_n), .x_in(x0), .x_in_valid(x0_valid),
    .tag_in(4'b0), .x_in_ready(), .x_out(x12), .x_out_valid(x12_valid),
    .layer_idx(layer_idx), .layer_done(loop_done),
    .tile_sel(), .fifo_lane_en_ilp(), .fifo_lane_en_olp(),
    .theta_req(), .theta_ack(1'b0), .sw_result_in(24576'b0),
    .recal_trig(1'b0)
  );
  pooler_cls_head #(.S(S), .H(H)) u_head (
    .clk(clk), .rst_n(rst_n), .tok_stream_in(x12q),
    .seq_start(loop_done),
    .margin_out(), .pred_out(pred_out),
    .correct_out(), .total_out(), .done(done)
  );
endmodule
