// tb_embed_lut.v — self-checking lookup test vs baked checkpoint bytes.
//
// DUTs: full config (H=576, V=32000, sparse baked init: 8 tested rows
// hold embed_full.hex bytes, all other rows zero) + mini config
// (H=8, V=1024) proving the parametric contract. Oracle files are
// produced by gen_golden.py straight from weights/bake/embed_full.hex
// and cross-checked byte-for-byte against tv_embed_golden.hex.
// DUT has 1-cycle registered latency: id sampled at posedge N is
// visible on vec after posedge N+1. Out-of-range ids (>= V) read zero.
module tb_embed_lut;
  localparam HF = 576;
  localparam VF = 32000;
  localparam HM = 8;
  localparam VM = 1024;
  localparam NF = 8;
  localparam NM = 7;

  reg clk = 0;
  always #5 clk = ~clk;

  reg [14:0] tok_full = 0;
  wire [HF*8-1:0] vec_full;
  embed_lut #(.E(576), .H(HF), .V(VF),
              .INIT_FILE("dut_init_full.hex")) dut_full (
    .clk(clk), .token_id(tok_full), .vec(vec_full)
  );

  reg [14:0] tok_mini = 0;
  wire [HM*8-1:0] vec_mini;
  embed_lut #(.E(8), .H(HM), .V(VM),
              .INIT_FILE("dut_init_mini.hex")) dut_mini (
    .clk(clk), .token_id(tok_mini), .vec(vec_mini)
  );

  reg [14:0]      ids_f [0:NF-1];
  reg [HF*8-1:0]  exp_f [0:NF-1];
  reg [14:0]      ids_m [0:NM-1];
  reg [HM*8-1:0]  exp_m [0:NM-1];

  integer errs = 0;
  integer got = 0;
  integer i;

  // Single lookup with exact 1-cycle latency (set at negedge, read at
  // the negedge after the sampling posedge).
  task check_full(input [14:0] id, input [HF*8-1:0] want);
    begin
      @(negedge clk);
      tok_full <= id;
      @(posedge clk);
      @(negedge clk);
      got = got + 1;
      if (vec_full !== want) begin
        $display("MISMATCH full id=%0d got[31:0]=%h want[31:0]=%h",
                 id, vec_full[31:0], want[31:0]);
        errs = errs + 1;
      end
    end
  endtask

  task check_mini(input [14:0] id, input [HM*8-1:0] want);
    begin
      @(negedge clk);
      tok_mini <= id;
      @(posedge clk);
      @(negedge clk);
      got = got + 1;
      if (vec_mini !== want) begin
        $display("MISMATCH mini id=%0d got=%h want=%h", id, vec_mini, want);
        errs = errs + 1;
      end
    end
  endtask

  initial begin
    $readmemh("ids_full.hex", ids_f);
    $readmemh("exp_full.hex", exp_f);
    $readmemh("ids_mini.hex", ids_m);
    $readmemh("exp_mini.hex", exp_m);
    #1;
    $display("ids_full[0]=%0d ids_full[3]=%0d (edges 0 / 31999)",
             ids_f[0], ids_f[3]);

    // 1) full-width spot lookups vs baked bytes (incl. edges 0, 31999)
    for (i = 0; i < NF; i = i + 1)
      check_full(ids_f[i], exp_f[i]);

    // 2) repeat read stability (id 0 twice more)
    check_full(ids_f[0], exp_f[0]);
    check_full(ids_f[3], exp_f[3]);

    // 3) back-to-back streaming burst, 1-cycle lag check
    @(negedge clk);
    tok_full <= ids_f[0];
    for (i = 1; i < NF; i = i + 1) begin
      @(negedge clk);
      got = got + 1;
      if (vec_full !== exp_f[i-1]) begin
        $display("MISMATCH burst id=%0d got[31:0]=%h want[31:0]=%h",
                 ids_f[i-1], vec_full[31:0], exp_f[i-1]);
        errs = errs + 1;
      end
      tok_full <= ids_f[i];
    end
    @(negedge clk);
    got = got + 1;
    if (vec_full !== exp_f[NF-1]) begin
      $display("MISMATCH burst id=%0d", ids_f[NF-1]);
      errs = errs + 1;
    end

    // 4) out-of-range + unprogrammed in-range rows read zero
    check_full(15'd32000, {HF*8{1'b0}});
    check_full(15'd32767, {HF*8{1'b0}});
    check_full(15'd16000, {HF*8{1'b0}});

    // 5) mini config: edges 0 / 1023 + mids, oor, unprogrammed
    for (i = 0; i < NM; i = i + 1)
      check_mini(ids_m[i], exp_m[i]);
    check_mini(15'd1500, {HM*8{1'b0}});
    check_mini(15'd500, {HM*8{1'b0}});

    #20;
    if (errs == 0)
      $display("EMBED_LUT PASS (%0d checks)", got);
    else
      $display("EMBED_LUT FAIL errs=%0d got=%0d", errs, got);
    $finish;
  end
endmodule
