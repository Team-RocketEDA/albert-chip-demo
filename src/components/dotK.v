// dotK — §00-E leaf. K-fold MAC loop reuse (embed DOT128 = K=128).
// Full K-dot in one shot: y = sum(a[i]*b[i]), signed, exact mod-2^32.
// Single-shot protocol: present avec/bvec with start=1; at the next
// posedge y latches and done pulses for exactly one cycle; y holds while
// start=0. Callers time-mux longer dots through repeated shots.
module dotK #(
  parameter W = 8,
  parameter K = 128
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             start,
  input  wire [K*W-1:0]   avec,
  input  wire [K*W-1:0]   bvec,
  output wire [31:0]      y, // exact low 32 bits (mod-2^32); see bound below
  output wire             done
);
  // Exactness bound (proven by tb_dotK_k128 + proof_dotK): the 64-bit psum
  // is exact iff K * 2^(2W-2) <= 2^63, i.e. K <= 2^(65-2W). y latches the
  // exact low 32 bits for every in-bound K (W=8: K <= 2^49, default 128);
  // no saturation or overflow handling is needed — wrap is the contract.
  // Out-of-bound K fails elaboration in every tool (unknown module).
  localparam [63:0] K_MAX = (2*W < 65) ? (64'd1 << (65-2*W)) : 64'd0;
  generate
    if (K > K_MAX) begin : gen_k_out_of_bound
      K_TIMES_2POW_2W_EXCEEDS_64BIT_PSUM_EXACTNESS_BOUND exceeded();
    end
  endgenerate
  reg signed [31:0] y_r;
  reg               done_r;
  assign y    = y_r;
  assign done = done_r;

  reg signed [63:0] psum;
  integer i;
  always @(*) begin
    psum = 64'sd0;
    for (i = 0; i < K; i = i + 1)
      psum = psum + $signed(avec[i*W+:W]) * $signed(bvec[i*W+:W]);
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      y_r    <= 32'sd0;
      done_r <= 1'b0;
    end else begin
      done_r <= start;
      if (start)
        y_r <= psum[31:0];
    end
  end
endmodule
