// attention_core — L1 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM decoder attention (GQA + causal + KV cache + RoPE).
// Parent I/O: Q[Sx576]s8, K[Sx192]s8, V[Sx192]s8 -> Y[Sx576]s8.
module attention_core #(
  parameter S = 64,
  parameter H = 576,
  parameter KV = 192
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
  wire [S*16-1:0] scores;
  wire [S*16-1:0] probs;
  wire            sm_valid;

  sram_1r1w #(.W(512), .N(128)) u_qbuf (
    .clk(clk), .ra(), .wa(), .wdata(512'b0), .we(qkv_valid), .rdata()
  );
  sram_1r1w #(.W(192), .N(128)) u_kbuf (
    .clk(clk), .ra(), .wa(), .wdata(192'b0), .we(qkv_valid), .rdata()
  );
  sram_1r1w #(.W(192), .N(128)) u_vbuf (
    .clk(clk), .ra(), .wa(), .wdata(192'b0), .we(qkv_valid), .rdata()
  );
  // KV cache (decode): 2048-token window per head-dim slice.
  sram_1r1w #(.W(192), .N(2048)) u_kcache (
    .clk(clk), .ra(), .wa(), .wdata(192'b0), .we(1'b0), .rdata()
  );
  sram_1r1w #(.W(192), .N(2048)) u_vcache (
    .clk(clk), .ra(), .wa(), .wdata(192'b0), .we(1'b0), .rdata()
  );
  // RoPE rotation on Q/K: sin/cos mult-add pairs, inferred * at implementation.
  mac_array #(.W(8), .P(32)) u_qk (
    .clk(clk), .rst_n(rst_n), .ce(qkv_valid), .clr(1'b0),
    .avec(), .bvec(), .acc_in(32'b0), .acc_out()
  );
  // scale L_raw/8: inferred >>3 at implementation.
  softmax_d #(.W(16), .S(S)) u_softmax (
    .clk(clk), .rst_n(rst_n), .scores(scores),
    .scores_valid(qkv_valid), .causal(1'b1),
    .probs(probs), .probs_valid(sm_valid)
  );
  sram_1r1w #(.W(16), .N(4096)) u_score (
    .clk(clk), .ra(), .wa(), .wdata(16'b0), .we(sm_valid), .rdata()
  );
  mac_array #(.W(8), .P(32)) u_av (
    .clk(clk), .rst_n(rst_n), .ce(sm_valid), .clr(1'b0),
    .avec(), .bvec(), .acc_in(32'b0), .acc_out()
  );
  fifo_sync #(.W(512), .D(4)) u_outfifo (
    .clk(clk), .rst_n(rst_n), .wdata(), .wr(sm_valid),
    .rd(), .rdata(), .full(), .empty()
  );

  // y_out / qkv_ready float here by design: driven at implementation.
endmodule
