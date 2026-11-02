// inproj_tile — L1 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM decoder QKV (GQA). Parent I/O: tok[Sx576]s8 ->
// Q[Sx576]s8 + K[Sx192]s8 + V[Sx192]s8 (packed QKV [Sx960]s8).
module inproj_tile #(
  parameter S = 64,
  parameter H = 576,
  parameter KV = 192,
  parameter C = 256
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [S*H*8-1:0]    tok_in,
  input  wire                tok_valid,
  input  wire [15:0]         cfg_scale, // per-chunk requant scale
  input  wire [15:0]         cfg_zero,  // per-chunk requant zero
  output wire                tok_ready,
  output wire [S*(H+2*KV)*8-1:0] y_out,
  output wire                y_valid
);
  wire [C*8-1:0] chunk;
  wire [31:0]    psum;
  wire           mac_done;

  fifo_sync #(.W(4608), .D(8)) u_infifo (
    .clk(clk), .rst_n(rst_n), .wdata(), .wr(tok_valid),
    .rd(), .rdata(), .full(), .empty()
  );
  sram_1r1w #(.W(8), .N(4096)) u_wsram (
    .clk(clk), .ra(), .wa(), .wdata(8'b0), .we(1'b0), .rdata()
  );
  mac_array #(.W(8), .P(32)) u_mac (
    .clk(clk), .rst_n(rst_n), .ce(tok_valid), .clr(1'b0),
    .avec(), .bvec(), .acc_in(32'b0), .acc_out(psum)
  );
  regfile_dp #(.W(32), .N(960)) u_accum (
    .clk(clk), .ra(), .rb(), .wa(), .wdata(psum), .we(1'b1),
    .rda(), .rdb()
  );
  adder #(.W(32)) u_bias (
    .a(psum), .b(32'b0), .y(), .cout()
  );
  requant #(.W(8)) u_requant (
    .clk(clk), .rst_n(rst_n), .acc_wide(psum),
    .scale(16'b0), .zero(16'b0), .act_int(), .valid(y_valid)
  );
  fifo_sync #(.W(4096), .D(8)) u_outfifo (
    .clk(clk), .rst_n(rst_n), .wdata(), .wr(y_valid),
    .rd(), .rdata(), .full(), .empty()
  );
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(tok_valid),
    .prefill(1'b1),
    .irq_tile_done(y_valid), .irq_frame_done(1'b0),
    .phase_sel(), .layer_idx(), .cal_addr(),
    .fifo_lane_en_ilp(), .fifo_lane_en_olp(),
    .fifo_rd(tok_ready), .layer_done()
  );

  // y_out floats here by design: driven at implementation.
endmodule
