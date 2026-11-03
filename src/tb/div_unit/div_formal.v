// div_formal.v — sby wrapper for div_unit (step 11).
// Binds div_unit #(.W(8)) (small width keeps the multiplier bounds in the
// proof cheap; the tb covers W=32/W=16). Strategy: register last-cycle
// inputs, then assert the independent remainder contract
//   denom==0 -> quot saturates all-ones
//   denom!=0 -> quot*denom <= numer < (quot+1)*denom   (2W-bit products)
// plus the single-shot protocol (done == past start, output holds while
// start=0) and reset values. The remainder bounds do not reuse the DUT's
// `/` operator, so the proof is not circular.
module div_formal (
  input wire clk,
  input wire rst_n,
  input wire start,
  input wire [7:0] numer,
  input wire [7:0] denom
);
  wire [7:0] quot;
  wire       done;

  div_unit #(.W(8)) dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .numer(numer), .denom(denom), .quot(quot), .done(done)
  );

  reg f_past_valid = 1'b0;
  reg p_start;
  reg [7:0] p_numer, p_denom;

  // Proof starts from reset (release is solver-chosen); without this the
  // solver begins in an arbitrary unreset state and the checks are vacuous.
  initial assume (!rst_n);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_past_valid <= 1'b0;
      p_start <= 1'b0;
      p_numer <= 8'd0;
      p_denom <= 8'd0;
    end else begin
      f_past_valid <= 1'b1;
      p_start <= start;
      p_numer <= numer;
      p_denom <= denom;
    end
  end

  // Remainder contract in 16-bit products (no overflow at W=8).
  wire [15:0] prod  = quot * p_denom;
  wire [15:0] prod1 = (quot + 8'd1) * p_denom;

  always @(posedge clk) begin
    if (f_past_valid && rst_n) begin
      // Single-shot protocol: done follows start by exactly one cycle.
      assert (done == p_start);
      if (!p_start) begin
        // Output holds while idle.
        assert ($stable(quot));
        assert (done == 1'b0);
      end else if (p_denom == 8'd0) begin
        assert (quot == 8'hFF);
      end else begin
        // quot = floor(p_numer / p_denom): exact to 0 ulp.
        assert (prod <= {8'd0, p_numer});
        assert ({8'd0, p_numer} < prod1);
      end
      // Covers: saturate rail, zero quotient, exact divide, max divide.
      cover (p_start && p_denom == 8'd0);
      cover (p_start && p_denom != 8'd0 && p_numer < p_denom);
      cover (p_start && p_denom != 8'd0 && prod == {8'd0, p_numer});
      cover (p_start && p_numer == 8'hFF && p_denom == 8'h01);
    end
    // Reset values observable at release.
    if (f_past_valid && !rst_n) begin
      assert (quot == 8'd0);
      assert (done == 1'b0);
    end
  end
endmodule
