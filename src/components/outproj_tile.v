// outproj_tile — L1 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM decoder out-proj. Parent I/O: Z[Sx576] -> Zout[Sx576].
// Column-split: tile holds cols [t*C:(t+1)*C]; concat MUX reassembles.
module outproj_tile #(
  parameter S = 64,
  parameter H = 576,
  parameter C = 256
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire [S*H*8-1:0] z_in,
  input  wire             z_valid,
  output wire             z_ready,
  output wire [S*C*8-1:0] slice_out,
  output wire             slice_valid
);
  wire [31:0] psum;

  fifo_sync #(.W(4608), .D(8)) u_infifo (
    .clk(clk), .rst_n(rst_n), .wdata(), .wr(z_valid),
    .rd(), .rdata(), .full(), .empty()
  );
  sram_1r1w #(.W(8), .N(4096)) u_wsram (
    .clk(clk), .ra(), .wa(), .wdata(8'b0), .we(1'b0), .rdata()
  );
  mac_array #(.W(8), .P(32)) u_mac (
    .clk(clk), .rst_n(rst_n), .ce(z_valid), .clr(1'b0),
    .avec(), .bvec(), .acc_in(32'b0), .acc_out(psum)
  );
  regfile_dp #(.W(32), .N(256)) u_accum (
    .clk(clk), .ra(), .rb(), .wa(), .wdata(psum), .we(1'b1),
    .rda(), .rdb()
  );
  shifter #(.W(32)) u_shift (
    .din(psum), .shamt(5'd0), .dout()
  );
  adder #(.W(32)) u_bias (
    .a(psum), .b(32'b0), .y(), .cout()
  );
  fifo_sync #(.W(2048), .D(8)) u_outfifo (
    .clk(clk), .rst_n(rst_n), .wdata(), .wr(slice_valid),
    .rd(), .rdata(), .full(), .empty()
  );
  muxN #(.W(8), .N(3)) u_concat (
    .sel(2'b0), .din(24'b0), .dout()
  ); // 3-slice column concat
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(z_valid),
    .prefill(1'b1),
    .irq_tile_done(slice_valid), .irq_frame_done(1'b0),
    .phase_sel(), .layer_idx(), .cal_addr(),
    .fifo_lane_en_ilp(), .fifo_lane_en_olp(),
    .fifo_rd(z_ready), .layer_done()
  );

  // slice_out floats here by design: driven at implementation.
endmodule
