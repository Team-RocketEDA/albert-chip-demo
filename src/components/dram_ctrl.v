// dram_ctrl — §00-E leaf, off-chip DRAM (embed spill only).
// Parked on the inference path (S<=64 never spills); instantiated only if S
// outgrows on-chip SRAM. Behavioral model for sim/formal, not a PHY.
// Protocol: in IDLE, req latches addr and starts a burst; ack asserts for
// exactly one cycle LATENCY cycles after the accepting edge, with the
// 256-bit line on rdata. Holding req through DONE chains the next burst.
// Addr map: addr[31:5] selects a 32-byte line, addr[4:0] is ignored.
// Packing: byte k of a line sits at rdata[8k+7:8k] (byte0 = LSB).
// Backing store: NLINES lines, zero-filled; INIT_FILE optionally preloads
// them with $readmemh (one 64-char hex word per line). A line index past
// the store (spill miss) still completes with zero data — the bus never
// hangs. rst_n is synchronous active-low (repo convention, PARAMS §6
// single-clock): sampled at posedge, returns the controller to IDLE with
// ack low. LATENCY must be >= 2 and NLINES >= 2.
// Ports are unchanged from the skeleton contract.
module dram_ctrl #(
  parameter LATENCY = 4,
  parameter NLINES = 256,
  parameter INIT_FILE = ""
)(
  input  wire         clk,
  input  wire         rst_n,
  input  wire         req,
  input  wire [31:0]  addr,
  output wire [255:0] rdata,
  output wire         ack
);
  localparam IDLE = 2'd0;
  localparam BUSY = 2'd1;
  localparam DONE = 2'd2;

  reg [255:0] mem [0:NLINES-1];
  reg [1:0]   st_q;
  reg [31:0]  cnt_q;
  reg [31:0]  addr_q;
  reg [255:0] rdata_q;
  reg         ack_q;
  integer i;

  localparam LAW = $clog2(NLINES);
  wire [26:0] line_idx = addr_q[31:5];
  wire        line_hit = line_idx < NLINES;
  wire [LAW-1:0] line_sel = line_idx[LAW-1:0];

  initial begin
    for (i = 0; i < NLINES; i = i + 1) mem[i] = 256'b0;
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      st_q <= IDLE;
      cnt_q <= 32'd0;
      addr_q <= 32'd0;
      rdata_q <= 256'b0;
      ack_q <= 1'b0;
    end else begin
      case (st_q)
        IDLE: begin
          ack_q <= 1'b0;
          if (req) begin
            addr_q <= addr;
            cnt_q <= 32'd0;
            st_q <= BUSY;
          end
        end
        BUSY: begin
          if (cnt_q == LATENCY - 1) begin
            if (line_hit)
              rdata_q <= mem[line_sel];
            else
              rdata_q <= 256'b0;
            ack_q <= 1'b1;
            st_q <= DONE;
          end else begin
            cnt_q <= cnt_q + 32'd1;
          end
        end
        DONE: begin
          ack_q <= 1'b0;
          if (req) begin
            addr_q <= addr;
            cnt_q <= 32'd0;
            st_q <= BUSY;
          end else begin
            st_q <= IDLE;
          end
        end
        default: begin
          st_q <= IDLE;
          ack_q <= 1'b0;
        end
      endcase
    end
  end

  assign rdata = rdata_q;
  assign ack = ack_q;
endmodule
