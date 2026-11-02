// tb_embed.v — self-checking: streams ids.hex, compares rows vs golden.hex.
module tb_embed;
  parameter V = 16, E = 8, H = 8, S = 4, SHIFT = 4;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg  [7:0]    tok_id = 0;
  reg            tok_valid = 0;
  wire           tok_ready;
  wire [H*8-1:0] row_out;
  wire           row_valid;

  embed #(.V(V), .E(E), .H(H), .SHIFT(SHIFT)) dut (
    .clk(clk), .rst_n(rst_n),
    .tok_id(tok_id), .tok_valid(tok_valid), .tok_ready(tok_ready),
    .row_out(row_out), .row_valid(row_valid)
  );

  reg [7:0]     ids    [0:S-1];
  reg [H*8-1:0] golden [0:S-1];
  integer i, errs = 0, got = 0;

  always @(posedge clk) begin
    if (row_valid) begin
      if (got < S) begin
        if (row_out !== golden[got]) begin
          $display("MISMATCH row %0d: got %h want %h", got, row_out, golden[got]);
          errs = errs + 1;
        end
      end else begin
        errs = errs + 1;
      end
      got = got + 1;
    end
  end

  initial begin
    $readmemh("ids.hex", ids);
    $readmemh("golden.hex", golden);
    #12 rst_n = 1;
    for (i = 0; i < S; i = i + 1) begin
      @(posedge clk);
      tok_id    <= ids[i];
      tok_valid <= 1'b1;
    end
    @(posedge clk);
    tok_valid <= 1'b0;
    #100;
    if (errs == 0 && got == S) $display("EMBED PASS (%0d rows)", S);
    else                        $display("EMBED FAIL errs=%0d got=%0d", errs, got);
    $finish;
  end
endmodule
