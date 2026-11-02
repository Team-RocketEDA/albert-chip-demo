// ffn_tile — L1 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM SwiGLU FFN. X[Sx576] -> gate/up (576->1536) ->
// silu(gate)*up -> down (1536->576) -> Y[Sx576].
module ffn_tile #(
  parameter S  = 64,
  parameter H  = 576,
  parameter FF = 1536
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire [S*H*8-1:0]  x_in,
  input  wire              x_valid,
  input  wire              start, // frame start
  output wire              x_ready,
  output wire [S*H*8-1:0]  y_out,
  output wire              y_valid,
  output wire              done   // frame done
);
  wire [31:0] gate_psum;
  wire [31:0] up_psum;
  wire [15:0] gate_act;
  wire [31:0] down_psum;
  wire        mid_done; // sequenced at implementation
  wire        ctrl_done;

  fifo_sync #(.W(512), .D(2)) u_inffo (
    .clk(clk), .rst_n(rst_n), .wdata(), .wr(x_valid),
    .rd(), .rdata(), .full(), .empty()
  );
  sram_1r1w #(.W(8), .N(8192)) u_gatew (
    .clk(clk), .ra(), .wa(), .wdata(8'b0), .we(1'b0), .rdata()
  );
  sram_1r1w #(.W(8), .N(8192)) u_upw (
    .clk(clk), .ra(), .wa(), .wdata(8'b0), .we(1'b0), .rdata()
  );
  mac_array #(.W(8), .P(32)) u_gate (
    .clk(clk), .rst_n(rst_n), .ce(x_valid), .clr(1'b0),
    .avec(), .bvec(), .acc_in(32'b0), .acc_out(gate_psum)
  );
  mac_array #(.W(8), .P(32)) u_up (
    .clk(clk), .rst_n(rst_n), .ce(x_valid), .clr(1'b0),
    .avec(), .bvec(), .acc_in(32'b0), .acc_out(up_psum)
  );
  silu_lut #(.W(16)) u_silu (
    .x(gate_psum[15:0]), .y(gate_act)
  );
  // gate*up elementwise: inferred * at implementation.
  fifo_sync #(.W(128), .D(8)) u_midffo (
    .clk(clk), .rst_n(rst_n), .wdata(), .wr(1'b0),
    .rd(), .rdata(), .full(), .empty()
  );
  sram_1r1w #(.W(8), .N(8192)) u_downw (
    .clk(clk), .ra(), .wa(), .wdata(8'b0), .we(1'b0), .rdata()
  );
  mac_array #(.W(8), .P(32)) u_down (
    .clk(clk), .rst_n(rst_n), .ce(x_valid), .clr(1'b0),
    .avec(), .bvec(), .acc_in(32'b0), .acc_out(down_psum)
  );
  regfile_dp #(.W(32), .N(576)) u_accum (
    .clk(clk), .ra(), .rb(), .wa(), .wdata(down_psum), .we(1'b1),
    .rda(), .rdb()
  );
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(x_valid),
    .prefill(1'b1),
    .irq_tile_done(mid_done), .irq_frame_done(1'b0),
    .phase_sel(), .layer_idx(), .cal_addr(),
    .fifo_lane_en_ilp(), .fifo_lane_en_olp(),
    .fifo_rd(x_ready), .layer_done(ctrl_done)
  );

  // y_valid + done converge onto ctrl_done at implementation (single net).
  // silu(gate)*up product and gate/up partial sums tap at implementation.
endmodule
