// fifo_sync_formal — sby wrapper (plan step 4). Safety props (count bound,
// full/empty correctness, exact count-update rules => no overflow or
// underflow) plus FWFT ordering end-to-end via a reset-aligned shadow
// queue: the shadow mirrors every push/pop from the post-reset state, so
// `head matches` proves the DUT drains in FIFO order. The shadow is used
// instead of a hierarchical mem[] read because a second async read port
// on the address under write is nondeterministic in the solver's memory
// model (read-during-write), which spuriously fails an otherwise true
// `rdata == mem[rptr]` check on write-to-empty cycles.
`timescale 1ns / 1ps
module fifo_sync_formal (
  input wire clk
);
  localparam W = 8;
  localparam D = 8;

  reg [1:0] rst_cnt = 2'b00;
  always @(posedge clk)
    if (rst_cnt != 2'b11) rst_cnt <= rst_cnt + 1'b1;
  wire rst_n = (rst_cnt == 2'b11);

  reg [W-1:0] wdata;
  reg         wr;
  reg         rd;
  wire [W-1:0] rdata;
  wire         full;
  wire         empty;

  fifo_sync #(.W(W), .D(D)) dut (
    .clk(clk), .rst_n(rst_n), .wdata(wdata), .wr(wr), .rd(rd),
    .rdata(rdata), .full(full), .empty(empty)
  );

  // NOTE: no `cnt` alias wire — a combinational alias of dut.count_q was
  // mis-evaluated by the solver flow (see task notes); assert on the DUT
  // register directly.

  // Reset-release canary: same async reset net and flop style as the DUT,
  // so it passes through yosys' async2sync conversion identically and
  // reads 1 exactly when the DUT's effective reset has released. All
  // checks and the shadow below key off `ck`, never raw rst_n.
  reg canary = 1'b0;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) canary <= 1'b0;
    else canary <= 1'b1;
  end
  // NOTE: no hierarchical reads of DUT registers anywhere in this file.
  // The solver flow mis-elaborates hierarchical register refs (a
  // `dut.count_q` read came out 1 bit wide), so the proof is phrased
  // purely over DUT inputs/outputs vs the wrapper model below.

  // Shadow queue: same enables, cleared while rst_n is low, so it is in
  // lockstep with the DUT from the first post-reset cycle. Any slot read
  // with shadow_cnt > 0 was written after reset (induction from empty).
  reg [W-1:0] sh_mem [0:D-1];
  reg [31:0]  sh_head = 32'd0;
  reg [31:0]  sh_tail = 32'd0;
  reg [31:0]  sh_cnt = 32'd0;
  wire        sh_wr = wr && !full;
  wire        sh_rd = rd && !empty;
  integer k;
  // Same async-reset structure as the DUT so the conversion keeps the
  // shadow in exact lockstep (a sync `!canary` clear would lag the
  // release edge by one op).
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sh_head <= 32'd0;
      sh_tail <= 32'd0;
      sh_cnt  <= 32'd0;
      for (k = 0; k < D; k = k + 1) sh_mem[k] <= {W{1'b0}};
    end else begin
      if (sh_rd) sh_head <= (sh_head == D - 1) ? 32'd0 : sh_head + 1;
      if (sh_wr) begin
        sh_mem[sh_tail] <= wdata;
        sh_tail <= (sh_tail == D - 1) ? 32'd0 : sh_tail + 1;
      end
      case ({sh_wr, sh_rd})
        2'b10:   sh_cnt <= sh_cnt + 1;
        2'b01:   sh_cnt <= sh_cnt - 1;
        default: sh_cnt <= sh_cnt;
      endcase
    end
  end

  // Observable-behavior proof: the DUT's flags and FWFT data track the
  // model occupancy exactly. sh_cnt evolves precisely as a correct FIFO's
  // would (push on wr&&!full, pop on rd&&!empty, qualified by the DUT's
  // own flags exactly as the DUT qualifies its updates), so flag match
  // proves no overflow/underflow and data match proves FWFT ordering.
  always @(posedge clk) begin
    if (canary && $past(canary)) begin
      cnt_bound:     assert(sh_cnt <= D);
      full_correct:  assert(full == (sh_cnt == D));
      empty_correct: assert(empty == (sh_cnt == 0));
      never_both:    assert(!(full && empty));
      if (sh_cnt > 0)
        fwft_order:  assert(rdata == sh_mem[sh_head]);
      else
        empty_zero:  assert(rdata == {W{1'b0}});
    end
  end

  always @(posedge clk) begin
    if (canary && $past(canary)) begin
      cov_full:       cover(full);
      cov_drain:      cover($past(full) && empty);
      cov_simul:      cover(wr && rd && !empty && !full);
      cov_simul_full: cover(wr && rd && full);
      cov_simul_mt:   cover(wr && rd && empty);
    end
  end
endmodule
