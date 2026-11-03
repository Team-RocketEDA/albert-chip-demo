// seq_fsm — hardwired IRQ-driven layer/phase sequencer (step 6, logic).
// Contract: blocks/08-loop-mem-seq.md D + ADR-0001 (hardwired phase/IRQ
// sequencer; NO RV32; firmware/mcu_fw.c is the golden C model) + doc 08-D
// (layer_counter, phase_decoder: tile_sel/fifo_lane_en/cal_addr).
// Decoder modes: prefill = full-sequence pass, decode = one token + KV cache.
// Behavior (IRQ priority: frame > tile > row; DONE sticky until reset):
//   irq_frame_done: layer-boundary IRQ (fw layer_done_isr): l<29 -> l+1,
//                   l==29 -> DONE. Resets phase/chunk/col.
//   irq_tile_done:  phase-boundary IRQ (fw phase_isr): p<3 -> p+1, p==3 ->
//                   next layer (or DONE at l==29). Resets chunk/col.
//   irq_row_done:   row/chunk IRQ: col+1, chunk+1 on col wrap.
//   prefill: 1 -> fifo_rd asserted whenever not DONE (streaming full pass);
//            0 -> fifo_rd only during p0 (single-token decode issue).
// cal_addr = {layer5b, block2b=phase, phase2b, chunk6b, col8b} (08-D4);
// block: p0 INPROJ=0, p1 OUTPROJ=1, p2 GATE/UP=2, p3 DOWN=3.
// fifo_lane_en per 09-interface per-phase routing table.
module seq_fsm (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        irq_row_done,
  input  wire        irq_tile_done,
  input  wire        irq_frame_done,
  input  wire        prefill,      // 1 = prefill pass, 0 = decode token
  output wire [3:0]  phase_sel,    // one-hot-per-phase (tile_sel)
  output wire [4:0]  layer_idx,    // 08-D1 layer counter l=0..29
  output wire [22:0] cal_addr,     // 08-D4 use select {layer5,block,phase,chunk,col}
  output wire [5:0]  fifo_lane_en_ilp,
  output wire [5:0]  fifo_lane_en_olp,
  output wire        fifo_rd,
  output wire        layer_done
);
  localparam NLAYERS = 5'd29;  // last layer index (l=0..29, 30 uses)
  localparam NPHASE  = 2'd3;   // last phase index (p=0..3)

  reg [4:0] layer_q;
  reg [1:0] phase_q;
  reg [5:0] chunk_q;
  reg [7:0] col_q;
  reg       done_q;

  always @(posedge clk) begin
    if (!rst_n) begin
      layer_q <= 5'd0;
      phase_q <= 2'd0;
      chunk_q <= 6'd0;
      col_q   <= 8'd0;
      done_q  <= 1'b0;
    end else if (!done_q) begin
      if (irq_frame_done) begin
        if (layer_q == NLAYERS)
          done_q <= 1'b1;  // freeze phase/chunk/col: sticky DONE
        else begin
          chunk_q <= 6'd0;
          col_q   <= 8'd0;
          phase_q <= 2'd0;
          layer_q <= layer_q + 5'd1;
        end
      end else if (irq_tile_done) begin
        if (phase_q == NPHASE) begin
          if (layer_q == NLAYERS)
            done_q <= 1'b1;  // freeze phase/chunk/col: sticky DONE
          else begin
            phase_q <= 2'd0;
            chunk_q <= 6'd0;
            col_q   <= 8'd0;
            layer_q <= layer_q + 5'd1;
          end
        end else begin
          phase_q <= phase_q + 2'd1;
          chunk_q <= 6'd0;
          col_q   <= 8'd0;
        end
      end else if (irq_row_done) begin
        col_q <= col_q + 8'd1;
        if (col_q == 8'hFF)
          chunk_q <= chunk_q + 6'd1;
      end
    end
  end

  assign phase_sel = 4'b0001 << phase_q;  // always one-hot
  assign layer_idx = layer_q;
  assign cal_addr  = {layer_q, phase_q, phase_q, chunk_q, col_q};

  // Per-phase lane steering (09-interface routing table, inferred MUX).
  assign fifo_lane_en_ilp = (phase_q == 2'd3) ? 6'b111111 : 6'b000011;
  assign fifo_lane_en_olp = (phase_q == 2'd0) ? 6'b011111 :
                            (phase_q == 2'd1) ? 6'b000111 :
                            (phase_q == 2'd2) ? 6'b111111 : 6'b000011;

  assign fifo_rd   = ~done_q & (prefill | (phase_q == 2'd0));
  assign layer_done = done_q;

`ifdef FORMAL
  // Formal properties (sby): one-hot phases, 30-state reachability,
  // layer5b cal_addr format, no dead state (DONE reachable + sticky).
  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;

  // Power-up is in reset: the sequencer only leaves reset via rst_n release.
  always @(posedge clk) begin
    if (!f_past_valid) assume (!rst_n);
  end

  always @(posedge clk) begin
    if (f_past_valid && rst_n) begin
      assert ($onehot(phase_sel));
      assert (layer_idx <= NLAYERS);
      assert (cal_addr[22:18] == layer_idx);
      assert (cal_addr[17:16] == {phase_q});   // block2b = phase
      assert (cal_addr[15:14] == phase_q);     // phase2b = phase
    end
    // DONE is terminal and sticky: no dead state past completion.
    if (f_past_valid && $past(rst_n) && $past(layer_done) && rst_n)
      assert (layer_done);
    if (f_past_valid && rst_n) begin
      cover (layer_idx == 5'd0 && phase_sel == 4'b0001);
      cover (layer_idx == 5'd15);
      cover (layer_idx == 5'd29 && phase_sel == 4'b1000);
      cover (layer_done);
    end
  end
`endif

endmodule
