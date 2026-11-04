// embed_top — L1 stitch (Stage A): ids -> X0 frame.
// Contract: MobileLLM tied embeddings (32k shared in/out, E=576, no
// factorized 128-dim proj). Parent I/O: ids[S]u15 -> X0[Sx576]s8.
// Direct lookup: ids -> LUT row (int8) -> skid -> DBUF frame store.
//
// Data: u_idfifo (serial u15 ids, low slice of ids_in) -> u_emb_lut
// (15-bit token_id, 1-cycle registered; OOR ids read zero) -> u_xbuf
// (576B skid) -> u_dbuf (byte SRAM bank, S*H bytes) -> x0_out frame.
// x0_out is sourced from a u_dbuf readback: every frame byte is written
// to then read from the SRAM before it appears on the port.
// Control: u_ctrl (seq_fsm, prefill=1). ids_ready = fifo_rd & ~full;
// frame-end bursts irq_frame_done 30x to walk layers 0..29 -> DONE, so
// x0_valid = layer_done (sticky till rst_n). Phase/layer/cal fan out
// unused here. Protocol: push exactly S ids (one/valid-beat, honoring
// ids_ready), wait x0_valid, sample x0_out. Single frame per reset.
//
// INIT_FILE: packed-row $readmemh image for u_emb_lut (one H-byte
// MSB-first line per vocab row, vec[8k+7:8k] == row byte k). The path
// resolves from the repo root (benches run from there); "" keeps zeros.
// Default backs the 8 tv_embed rows (gen: src/tb/embed_top_stitch/
// gen_dut_init.py); unbacked in-range rows read zero under this image.
// Weight-path override: VERILOG_DEFINES (LibreLane) or -D (hand flow)
// injects an absolute path; default stays repo-root-relative for sim.
`ifndef ET_INIT_PATH
`define ET_INIT_PATH "src/tb/embed_top_stitch/dut_init.hex"
`endif
module embed_top #(
  parameter S = 64,
  parameter E = 576,
  parameter H = 576,
  parameter V = 32000,
  parameter INIT_FILE = `ET_INIT_PATH
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire [S*16-1:0]   ids_in,
  input  wire              ids_valid,
  output wire              ids_ready,
  output wire [S*H*8-1:0]  x0_out,
  output wire              x0_valid
);
  localparam integer FRAME_BYTES = S * H;
  localparam [1:0] ST_FILL = 2'd0;
  localparam [1:0] ST_READ = 2'd1;
  localparam [1:0] ST_BURST = 2'd2;
  localparam [1:0] ST_HOLD = 2'd3;

  reg [1:0] state;

  // ID FIFO (serial ids).
  wire [15:0] fifo_rdata;
  wire        fifo_full;
  wire        fifo_empty;
  wire        pop_en;
  reg         pop_d; // lut_vec valid one cycle after pop_en

  // LUT row + skid.
  wire [H*8-1:0] lut_vec;
  wire           xbuf_full;
  wire           xbuf_empty;
  wire [H*8-1:0] xbuf_rdata;
  wire           xbuf_rd;

  // Row writer + frame readback.
  reg [H*8-1:0] row_q;
  reg           writing;
  reg [15:0]    byte_cnt;
  reg [15:0]    row_cnt;
  reg [15:0]    wr_addr;
  wire [15:0]   dbuf_ra;
  reg [15:0]    rd_addr;
  reg [15:0]    rd_cap;
  reg           cap_vld;
  reg           rd_drain;
  wire          dbuf_we;
  wire [7:0]    dbuf_wdata;
  wire [7:0]    dbuf_rdata;

  // Frame store (filled by the u_dbuf readback, drives the port).
  reg [S*H*8-1:0] frame_q;

  // Sequencer: fifo_rd backpressure out, layer_done frame-valid out.
  wire        fifo_rd_w;
  wire        layer_done_w;
  wire        burst_irq;

  assign pop_en  = (state == ST_FILL) && !fifo_empty && !xbuf_full && !writing;
  assign xbuf_rd = (state == ST_FILL) && !writing && !xbuf_empty;

  assign dbuf_we    = (state == ST_FILL) && writing;
  assign dbuf_wdata = row_q[byte_cnt*8 +: 8];
  assign dbuf_ra    = (state == ST_READ) ? rd_addr : 16'd0;

  assign burst_irq = (state == ST_BURST) && !layer_done_w;
  assign ids_ready = fifo_rd_w & ~fifo_full;
  assign x0_valid  = layer_done_w;
  assign x0_out    = frame_q;

  fifo_sync #(.W(16), .D(64)) u_idfifo (
    .clk(clk), .rst_n(rst_n),
    .wdata(ids_in[15:0]), .wr(ids_valid),
    .rd(pop_en), .rdata(fifo_rdata), .full(fifo_full), .empty(fifo_empty)
  );
  embed_lut #(.E(E), .H(H), .V(V), .INIT_FILE(INIT_FILE)) u_emb_lut (
    .clk(clk), .token_id(fifo_rdata[14:0]), .vec(lut_vec)
  );
  fifo_sync #(.W(H*8), .D(2)) u_xbuf (
    .clk(clk), .rst_n(rst_n),
    .wdata(lut_vec), .wr(pop_d && (state == ST_FILL)),
    .rd(xbuf_rd), .rdata(xbuf_rdata), .full(xbuf_full), .empty(xbuf_empty)
  );
  sram_1r1w #(.W(8), .N(36864)) u_dbuf (
    .clk(clk), .ra(dbuf_ra), .wa(wr_addr), .wdata(dbuf_wdata),
    .we(dbuf_we), .rdata(dbuf_rdata)
  ); // one S*H frame bank (covers S<=64 @H=576); ping-pong second bank later
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(1'b0), .irq_tile_done(1'b0),
    .irq_frame_done(burst_irq),
    .prefill(1'b1),
    .phase_sel(), .layer_idx(), .cal_addr(),
    .fifo_lane_en_ilp(), .fifo_lane_en_olp(),
    .fifo_rd(fifo_rd_w), .layer_done(layer_done_w)
  );

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= ST_FILL;
      pop_d    <= 1'b0;
      row_q    <= {H*8{1'b0}};
      writing  <= 1'b0;
      byte_cnt <= 16'd0;
      row_cnt  <= 16'd0;
      wr_addr  <= 16'd0;
      rd_addr  <= 16'd0;
      rd_cap   <= 16'd0;
      cap_vld  <= 1'b0;
      rd_drain <= 1'b0;
      frame_q  <= {(S*H*8){1'b0}};
    end else begin
      pop_d <= pop_en;
      if (state == ST_FILL) begin
        if (!writing && !xbuf_empty) begin
          row_q    <= xbuf_rdata;
          writing  <= 1'b1;
          byte_cnt <= 16'd0;
        end else if (writing) begin
          if (byte_cnt == H - 1) begin
            writing <= 1'b0;
            row_cnt <= row_cnt + 16'd1;
            if (row_cnt + 16'd1 == S)
              state <= ST_READ;
          end else begin
            byte_cnt <= byte_cnt + 16'd1;
          end
          wr_addr <= wr_addr + 16'd1;
        end
      end else if (state == ST_READ) begin
        if (cap_vld)
          frame_q[rd_cap*8 +: 8] <= dbuf_rdata;
        rd_cap <= rd_addr;
        if (rd_addr < FRAME_BYTES) begin
          rd_addr <= rd_addr + 16'd1;
          cap_vld <= 1'b1;
        end else begin
          cap_vld <= 1'b0;
          if (rd_drain)
            state <= ST_BURST;
          else
            rd_drain <= 1'b1;
        end
      end else if (state == ST_BURST) begin
        if (layer_done_w)
          state <= ST_HOLD;
      end
    end
  end
endmodule
