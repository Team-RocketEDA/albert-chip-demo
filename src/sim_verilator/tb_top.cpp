// tb_top.cpp — readable smoke driver for the full model (EXPECT X).
//
// Drives three token ids into mobilellm_top, runs a bounded window, and
// prints pred_out/done every 500 cycles so you can SEE the top-level
// handshake (or its absence) in the terminal AND in waves_top.fst.
//
// Today this is a plumbing check: pred_out floats in the structural
// hierarchy, so Verilator reads it as 0 and done stays low. When the
// stitching lands, this same bench becomes the token-in/token-out demo:
// feed ids, wait for done, read pred_out.
#include <cstdint>
#include <cstdio>

#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_fst_c.h"

static vluint64_t sim_time = 0;
static const int S = 64;

static void tick(Vtb_top *top, VerilatedFstC *tfp) {
  top->clk = 0; top->eval(); tfp->dump(sim_time++);
  top->clk = 1; top->eval(); tfp->dump(sim_time++);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_top *top = new Vtb_top;
  VerilatedFstC *tfp = new VerilatedFstC;
  Verilated::traceEverOn(true);
  top->trace(tfp, 99);
  tfp->open("src/sim_verilator/waves_top.fst");

  // ids_in is 64 x 16-bit lanes; lane j lives in word j/2, half (j%2).
  // ids 1, 2, 0x42 in lanes 0..2, rest padding 0.
  for (int w = 0; w < 32; w++) top->ids_in[w] = 0;
  top->ids_in[0] = (2u << 16) | 1u;
  top->ids_in[1] = 0x42u;
  top->start = 0; top->ids_valid = 0; top->rst_n = 0;
  tick(top, tfp); tick(top, tfp);
  top->rst_n = 1;
  tick(top, tfp); tick(top, tfp);

  printf("top: ids lanes 0..2 = {1, 2, 0x42}, valid pulsed, 3000 cycles\n");
  top->ids_valid = 1;
  tick(top, tfp); tick(top, tfp);
  top->ids_valid = 0;
  for (int c = 0; c < 3000; c++) {
    tick(top, tfp);
    if (c % 500 == 0)
      printf("  cyc %4d: pred_out=%5d done=%d  (structural: expect 0/0)\n",
             c, (int)top->pred_out, (int)top->done);
  }
  printf("TOP_SMOKE done: pred_out=%d done=%d (meaningful after stitching)\n",
         (int)top->pred_out, (int)top->done);
  tfp->close();
  return 0;
}
