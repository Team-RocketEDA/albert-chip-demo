// layernorm_stage — L1 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: blocks/05-layernorm.md. x[Sx768]fxp16 + resid -> y[Sx768]fxp16.
module layernorm_stage #(
  parameter S = 64,
  parameter H = 576
)( // RMSNorm: int8 in, fxp16 out; mean/var detail in layernorm_d
  input  wire              clk,
  input  wire              rst_n,
  input  wire [S*H*8-1:0] x_in, // int8 entry; s8<<8 widen inside (doc 05)
  input  wire [S*H*8-1:0] resid_in, // int8 entry; saturate-then-<<8 (doc 05)
  input  wire              in_valid,
  output wire              in_ready,
  output wire [S*H*16-1:0] y_out,
  output wire              y_valid
);
  wire [15:0] norm_y;
  wire        norm_valid;

  layernorm_d #(.W(16)) u_norm (
    .clk(clk), .rst_n(rst_n), .x(x_in[15:0]), .resid(resid_in[15:0]),
    .gamma(16'b0), .y(norm_y), .y_valid(norm_valid)
  );
  sram_1r1w #(.W(16), .N(98304)) u_tbuf ( // 192KB: 2 banks x S*D x16b
    .clk(clk), .ra(), .wa(), .wdata(norm_y), .we(norm_valid), .rdata()
  );
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(in_valid),
    .irq_tile_done(norm_valid), .irq_frame_done(1'b0),
    .phase_sel(), .cal_addr(), .fifo_rd(in_ready), .layer_done()
  );

  // y_out floats here by design: driven at implementation.
endmodule
