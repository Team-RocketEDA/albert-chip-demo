// loop_mem_seq — L1 wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM 30-layer loopback. X_in -> {p0..p3, attn, rms} x30 ->
// X_out; layer_done at l==29 hands to LM head.
module loop_mem_seq #(
  parameter S  = 64,
  parameter H  = 576,
  parameter FF = 1536,
  parameter C  = 256
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire [S*H*8-1:0]  x_in,
  input  wire              x_in_valid,
  input  wire [3:0]        tag_in,      // stream tag
  output wire              x_in_ready,
  output wire [S*H*8-1:0]  x_out,
  output wire              x_out_valid,
  output wire [4:0]        layer_idx,   // l=0..29
  output wire              layer_done,
  // phase-decoder fanout + top-port handshakes
  output wire [3:0]        tile_sel,
  output wire [5:0]        fifo_lane_en_ilp,
  output wire [5:0]        fifo_lane_en_olp,
  output wire              theta_req,   // to parent store
  input  wire              theta_ack,
  input  wire [768*32-1:0] sw_result_in, // SW-leg re-entry (768xacc)
  input  wire              recal_trig   // periodic coeff rotation
);
  wire [S*(H+384)*8-1:0] p0_y; // full QKV thirds (576+192+192), split below
  wire [S*H*8-1:0] attn_y;
  wire [S*C*8-1:0] p1_slice; // C-wide slice; 3-slice concat at implementation
  wire [S*H*8-1:0] ln1_x; // concat of p1 slices wired at implementation
  wire [S*H*8-1:0] p3_y;
  wire [S*H*16-1:0] ln1_y; // RMSNorm out; narrowed to int8 via u_ln1rq below
  wire [7:0]       ln1_b0; // first-lane requant tap (S lanes replicate)
  wire [S*H*8-1:0] ffn_x; // LN->requant->FFN path wired at implementation
  wire [3:0]       phase;
  wire [22:0]      coeff_addr;
  wire             p_valid;

  sram_1r1w #(.W(8), .N(8192)) u_xbank (
    .clk(clk), .ra(), .wa(), .wdata(8'b0), .we(x_in_valid), .rdata()
  );
  sram_1r1w #(.W(16), .N(32768)) u_wcal (
    .clk(clk), .ra(coeff_addr[14:0]), .wa(), .wdata(16'b0),
    .we(1'b0), .rdata()
  );
  // 6 ILP + 6 OLP lanes, DEPTH 8 (chunk-group drain at implementation).
  genvar g;
  generate
    for (g = 0; g < 6; g = g + 1) begin : ilp_lanes
      fifo_sync #(.W(1024), .D(8)) u_lane (
        .clk(clk), .rst_n(rst_n), .wdata(1024'b0), .wr(1'b0),
        .rd(1'b0), .rdata(), .full(), .empty()
      );
    end
    for (g = 0; g < 6; g = g + 1) begin : olp_lanes
      fifo_sync #(.W(4096), .D(8)) u_lane (
        .clk(clk), .rst_n(rst_n), .wdata(4096'b0), .wr(1'b0),
        .rd(1'b0), .rdata(), .full(), .empty()
      );
    end
  endgenerate
  inproj_tile #(.S(S), .H(H)) u_p0 (
    .clk(clk), .rst_n(rst_n), .tok_in(x_in), .tok_valid(x_in_valid),
    .cfg_scale(16'b0), .cfg_zero(16'b0),
    .tok_ready(), .y_out(p0_y), .y_valid(p_valid)
  );
  attention_core #(.S(S), .H(H)) u_attn (
    .clk(clk), .rst_n(rst_n),
    .q_in(p0_y[S*H*8-1:0]), .k_in(p0_y[S*H*8+S*192*8-1:S*H*8]),
    .v_in(p0_y[S*(H+384)*8-1:S*(H+192)*8]),
    .qkv_valid(p_valid), .s_cfg(7'd64), .qkv_ready(),
    .y_out(attn_y), .y_valid()
  );
  outproj_tile #(.S(S), .H(H)) u_p1 (
    .clk(clk), .rst_n(rst_n), .z_in(attn_y), .z_valid(p_valid),
    .z_ready(), .slice_out(p1_slice), .slice_valid()
  );
  layernorm_stage #(.S(S), .H(H)) u_ln1 (
    .clk(clk), .rst_n(rst_n), .x_in(ln1_x), .resid_in(x_in),
    .in_valid(p_valid), .in_ready(), .y_out(ln1_y), .y_valid()
  );
  requant #(.W(8)) u_ln1rq (
    .clk(clk), .rst_n(rst_n), .acc_wide(ln1_y[31:0]),
    .scale(16'b0), .zero(16'b0), .act_int(ln1_b0), .valid()
  );
  ffn_tile #(.S(S), .H(H), .FF(FF)) u_ffn (
    .clk(clk), .rst_n(rst_n), .x_in(ffn_x), .x_valid(p_valid),
    .start(x_in_valid), .x_ready(), .y_out(p3_y), .y_valid(), .done()
  );
  layernorm_stage #(.S(S), .H(H)) u_ln2 (
    .clk(clk), .rst_n(rst_n), .x_in(p3_y), .resid_in(attn_y),
    .in_valid(p_valid), .in_ready(), .y_out(), .y_valid(x_out_valid)
  );
  seq_fsm u_layerseq (
    .clk(clk), .rst_n(rst_n), .irq_row_done(x_in_valid),
    .prefill(1'b1),
    .irq_tile_done(p_valid), .irq_frame_done(x_out_valid),
    .phase_sel(tile_sel), .layer_idx(layer_idx), .cal_addr(coeff_addr),
    .fifo_lane_en_ilp(fifo_lane_en_ilp),
    .fifo_lane_en_olp(fifo_lane_en_olp),
    .fifo_rd(x_in_ready), .layer_done(layer_done)
  );
  seq_fsm u_recalseq (
    .clk(clk), .rst_n(rst_n), .irq_row_done(recal_trig),
    .prefill(1'b1),
    .irq_tile_done(1'b0), .irq_frame_done(layer_done),
    .phase_sel(phase), .layer_idx(), .cal_addr(),
    .fifo_lane_en_ilp(), .fifo_lane_en_olp(),
    .fifo_rd(), .layer_done()
  );
  irq_sync u_irq (
    .clk(clk), .irq_async(recal_trig), .irq()
  );
  // mcu_if: hardwired into u_layerseq; golden C in firmware/mcu_fw.c.
  // theta_req/ack + sw_result_in terminate at integration (parent store /
  // SW-leg re-entry); overflow parked.
  // x_out floats: LN fxp16->int8 narrowing + loopback MUX wire at
  // implementation.

  // phase/layer_idx/coeff_addr/lane enables fan out from u_layerseq above.
endmodule
