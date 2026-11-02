// embed_top — L1 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM tied embeddings (32k shared in/out, E=576, no
// factorized 128-dim proj). Parent I/O: ids[S]u15 -> X0[Sx576]s8.
module embed_top #(
  parameter S = 64,
  parameter E = 576,
  parameter H = 576,
  parameter V = 32000
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire [S*16-1:0]   ids_in,
  input  wire              ids_valid,
  output wire              ids_ready,
  output wire [S*H*8-1:0]  x0_out,
  output wire              x0_valid
);
  wire [H*8-1:0]  emb_vec;
  wire [31:0]     dot_y;
  wire            dot_done;

  fifo_sync #(.W(16), .D(64)) u_idfifo (
    .clk(clk), .rst_n(rst_n), .wdata(ids_in[15:0]), .wr(ids_valid),
    .rd(), .rdata(), .full(), .empty()
  );
  embed_lut #(.E(E), .H(H)) u_emb_lut (
    .clk(clk), .token_id(ids_in[14:0]), .vec(emb_vec)
  );
  fifo_sync #(.W(1024), .D(4)) u_e128fifo (
    .clk(clk), .rst_n(rst_n), .wdata(), .wr(1'b0),
    .rd(), .rdata(), .full(), .empty()
  );
  sram_1r1w #(.W(8), .N(32768)) u_projw (
    .clk(clk), .ra(), .wa(), .wdata(8'b0), .we(1'b0), .rdata()
  );
  dotK #(.W(8), .K(E)) u_dot (
    .clk(clk), .rst_n(rst_n), .start(ids_valid),
    .avec(), .bvec(), .y(dot_y), .done(dot_done)
  );
  regfile_dp #(.W(32), .N(768)) u_accum (
    .clk(clk), .ra(), .rb(), .wa(), .wdata(dot_y), .we(dot_done),
    .rda(), .rdb()
  );
  adder #(.W(32)) u_bias (
    .a(dot_y), .b(32'b0), .y(), .cout()
  );
  requant #(.W(8)) u_requant (
    .clk(clk), .rst_n(rst_n), .acc_wide(dot_y),
    .scale(16'b0), .zero(16'b0), .act_int(), .valid(x0_valid)
  );
  sram_1r1w #(.W(8), .N(16384)) u_dbuf (
    .clk(clk), .ra(), .wa(), .wdata(8'b0), .we(1'b0), .rdata()
  );
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(1'b0), .irq_tile_done(dot_done),
    .prefill(1'b1),
    .irq_frame_done(1'b0), .phase_sel(), .layer_idx(), .cal_addr(),
    .fifo_lane_en_ilp(), .fifo_lane_en_olp(),
    .fifo_rd(ids_ready), .layer_done()
  );

  // x0_out / ids_ready float here by design: driven at implementation.
endmodule
