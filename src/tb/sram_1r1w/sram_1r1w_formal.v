// sram_1r1w_formal — sby wrapper: proves write-then-read consistency.
// Property: a write accepted at cycle k (we && wa==ra sampled) is visible on
// rdata at cycle k+1, i.e. next-cycle rdata equals the written word.
module sram_1r1w_formal (
  input wire clk
);
  localparam W = 8;
  localparam N = 16;
  localparam AW = 4;

  reg [AW-1:0] ra, wa;
  reg [W-1:0]  wdata;
  reg          we;
  wire [W-1:0] rdata;

  sram_1r1w #(.W(W), .N(N)) dut (
    .clk(clk), .ra(ra), .wa(wa), .wdata(wdata), .we(we), .rdata(rdata)
  );

  reg f_valid = 1'b0;
  reg f_we;
  reg [AW-1:0] f_wa, f_ra;
  reg [W-1:0] f_wdata;

  always @(posedge clk) begin
    f_valid <= 1'b1;
    f_we <= we;
    f_wa <= wa;
    f_ra <= ra;
    f_wdata <= wdata;
    if (f_valid && f_we && (f_wa == f_ra))
      assert(rdata == f_wdata);
  end
endmodule
