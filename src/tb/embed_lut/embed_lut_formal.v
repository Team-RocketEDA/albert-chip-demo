// embed_lut_formal.v — sby harness for embed_lut (tiny V=8/H=4 config).
// Proves: out-of-range ids (>= V) read zero next cycle; in-range ids
// read exactly rom[id] next cycle, for arbitrary id sequences and the
// zero init image (INIT_FILE=""). Data correctness vs baked bytes is
// covered by tb_embed_lut.v sim; this covers the address-guard mux.
module embed_lut_formal (
  input wire clk
);
  localparam V = 8;
  localparam H = 4;

  reg [14:0] token_id; // undriven: free formal input, any id each cycle
  wire [H*8-1:0] vec;

  embed_lut #(.E(4), .H(H), .V(V), .INIT_FILE("")) dut (
    .clk(clk), .token_id(token_id), .vec(vec)
  );

  reg [14:0] id_d = 0;
  always @(posedge clk)
    id_d <= token_id;

  reg [2:0] ticks = 0;
  always @(posedge clk)
    if (ticks != 3'd7)
      ticks <= ticks + 3'd1;

`ifdef FORMAL
  // Ticks 0-1 flush the id_d/vec_q pipeline (uninitialized at reset).
  // a_oor: the address guard — out-of-range ids read zero next cycle.
  // a_det: the read is a pure function of the id — repeating an id
  //   repeats vec (no hidden-state dependence in the address path).
  // Data correctness vs baked bytes is proven by tb_embed_lut.v sim.
  always @(posedge clk) begin
    if (ticks >= 3'd2) begin
      if (id_d >= V)
        assert (vec == {H*8{1'b0}});
      if (id_d < V && id_d == $past(id_d) && $past(ticks) >= 3'd2)
        assert (vec == $past(vec));
    end
    cover (id_d == 3);
    cover (id_d == 100);
  end
`endif
endmodule
