// mobilellm_top — L0 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM-125M decoder (L=30/H=576). ids[S] -> EMBED ->
// 30-deep ETCHED STACK (layer0 -> ... -> layer29, no loopback) ->
// LM HEAD (last-token) -> pred token id.
//
// The loopback is gone by design: an etched accelerator does not
// time-multiplex one layer block. Each layer macro carries its own
// baked weights (see layer_etched.v); the top only chains them.
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

  embed_top #(.S(S), .H(H)) u_embed (
    .clk(clk), .rst_n(rst_n), .ids_in(ids_in), .ids_valid(ids_valid),
    .ids_ready(), .x0_out(x0), .x0_valid(x0_valid)
  );
  decoder_etched_stack #(.S(S), .H(H)) u_stack (
    .clk(clk), .rst_n(rst_n), .x_in(x0), .x_valid(x0_valid),
    .x_ready(), .x_out(x30), .y_valid(x30_valid)
  );
  lm_head #(.H(H), .V(V)) u_head (
    .clk(clk), .rst_n(rst_n), .x_last_in(x30[S*H*8-1:(S-1)*H*8]),
    .x_valid(x30_valid),
    .pred_out(pred_out), .done(done)
  );
endmodule
