// mobilellm_top — L0 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM-125M decoder (L=30/H=576). ids[S] -> EMBED ->
// LOOP 30x -> LM HEAD (last-token) -> pred token id.
module mobilellm_top #(
  parameter S = 64,
  parameter H = 576,
  parameter V = 32000
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
  wire [S*H*8-1:0] x30;
  wire             x30_valid;
  wire [4:0]       layer_idx;
  wire             loop_done;

  embed_top #(.S(S), .H(H)) u_embed (
    .clk(clk), .rst_n(rst_n), .ids_in(ids_in), .ids_valid(ids_valid),
    .ids_ready(), .x0_out(x0), .x0_valid(x0_valid)
  );
  loop_mem_seq #(.S(S), .H(H)) u_loop (
    .clk(clk), .rst_n(rst_n), .x_in(x0), .x_in_valid(x0_valid),
    .tag_in(4'b0), .x_in_ready(), .x_out(x30), .x_out_valid(x30_valid),
    .layer_idx(layer_idx), .layer_done(loop_done),
    .tile_sel(), .fifo_lane_en_ilp(), .fifo_lane_en_olp(),
    .theta_req(), .theta_ack(1'b0), .sw_result_in(18432'b0),
    .recal_trig(1'b0)
  );
  lm_head #(.H(H), .V(V)) u_head (
    .clk(clk), .rst_n(rst_n), .x_last_in(x30[S*H*8-1:(S-1)*H*8]),
    .x_valid(x30_valid && loop_done),
    .pred_out(pred_out), .done(done)
  );
endmodule
