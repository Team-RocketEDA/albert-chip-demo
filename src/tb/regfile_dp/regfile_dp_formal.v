// regfile_dp_formal — sby wrapper: proves the write-forward bypass and,
// under REGFILE_EQUIV, full array equivalence against a wrapper shadow model
// (base: both zero-filled; step: identical write enables). Bypass-only
// (default) is k-inductive; the shadow part is run in BMC from init.
module regfile_dp_formal (
  input wire clk
);
  localparam W = 32;
  localparam N = 16;
  localparam AW = 4;

  reg [AW-1:0] ra, rb, wa;
  reg [W-1:0]  wdata;
  reg          we;
  wire [W-1:0] rda, rdb;

  regfile_dp #(.W(W), .N(N)) dut (
    .clk(clk), .ra(ra), .rb(rb), .wa(wa), .wdata(wdata), .we(we),
    .rda(rda), .rdb(rdb)
  );

`ifdef REGFILE_EQUIV
  reg [W-1:0] shadow [0:N-1];
  integer j;
  initial begin
    for (j = 0; j < N; j = j + 1) shadow[j] = {W{1'b0}};
  end

  always @(posedge clk) begin
    if (we)
      shadow[wa] <= wdata;
  end

  always @(*) begin
    if (!(we && (wa == ra)))
      assert(rda == shadow[ra]);
    if (!(we && (wa == rb)))
      assert(rdb == shadow[rb]);
  end
`endif

  always @(*) begin
    if (we && (wa == ra))
      assert(rda == wdata);
    if (we && (wa == rb))
      assert(rdb == wdata);
  end
endmodule
