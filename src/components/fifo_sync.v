// fifo_sync — §00-E leaf, sync FWFT FIFO, DEPTH D, W bits wide.
// Contract: blocks/00-primitive-library.md §E. Ports/topology frozen.
// Semantics: wr/rd sampled on posedge clk (rst_n async-active-low).
// wr into full is ignored (no overflow), rd from empty is ignored (no
// underflow). Simultaneous wr+rd: pop head, then push wdata (count holds,
// one slot freed and refilled). FWFT: rdata always shows the head word,
// 0 when empty. Occupancy count_q sizes full/empty exactly.
module fifo_sync #(
  parameter W = 8,
  parameter D = 8
)(
  input  wire         clk,
  input  wire         rst_n,
  input  wire [W-1:0] wdata,
  input  wire         wr,
  input  wire         rd,
  output wire [W-1:0] rdata,
  output wire         full,
  output wire         empty
);
  // AW covers the D pointer values (min 1 bit so D=1 still elaborates);
  // CW covers counts 0..D.
  localparam integer AW = (D <= 2) ? 1 : $clog2(D);
  localparam integer CW = $clog2(D + 1);

  reg [W-1:0]  mem [0:D-1];
  reg [AW-1:0] wptr_q;
  reg [AW-1:0] rptr_q;
  reg [CW-1:0] count_q;

  assign full  = (count_q == D);
  assign empty = (count_q == 32'd0);
  assign rdata = empty ? {W{1'b0}} : mem[rptr_q];

  wire wr_en = wr && !full;
  wire rd_en = rd && !empty;

  wire [AW-1:0] wptr_n = (wptr_q == (D - 1)) ? {AW{1'b0}} : wptr_q + 1'b1;
  wire [AW-1:0] rptr_n = (rptr_q == (D - 1)) ? {AW{1'b0}} : rptr_q + 1'b1;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr_q  <= {AW{1'b0}};
      rptr_q  <= {AW{1'b0}};
      count_q <= {CW{1'b0}};
    end else begin
      if (wr_en) begin
        mem[wptr_q] <= wdata;
        wptr_q      <= wptr_n;
      end
      if (rd_en)
        rptr_q <= rptr_n;
      case ({wr_en, rd_en})
        2'b10:   count_q <= count_q + 1'b1;
        2'b01:   count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
    end
  end
endmodule
