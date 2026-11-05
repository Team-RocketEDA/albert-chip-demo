// tb_codec.cpp — single-token codec driver: one id in, pred id out.
// Prints CODEC pred=<id> cycles=<n> ns_per_token=<t> (25 ns clock).
// Multi-token generation chains runs (Makefile `codec` loops IDS, feeding
// each pred back as the next id) — one sim run per token, no rebuild.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vtb_codec.h"
#include "verilated.h"

static Vtb_codec *top;

static void tick() {
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  int id = (argc > 1) ? atoi(argv[1]) : 1;
  top = new Vtb_codec;
  top->clk = 0;
  top->rst_n = 0;
  top->token_id = (uint16_t)(id & 0x7FFF);
  top->id_valid = 0;
  for (int i = 0; i < 5; i++) tick();
  top->rst_n = 1;
  tick();
  tick();  // embed_lut 1-cycle latency settles evec
  top->id_valid = 1;
  tick();
  top->id_valid = 0;

  bool done = false;
  unsigned pred = 0;
  vluint64_t cyc = 0;
  while (!done && cyc < 20000000) {
    tick();
    cyc++;
    if (top->pred_done) {
      pred = top->pred_out;
      done = true;
    }
  }
  if (!done) {
    printf("CODEC FAIL timeout id=%d cyc=%llu\n", id,
           (unsigned long long)cyc);
    return 1;
  }
  // 25 ns clock: tokens/s measured for this single-layer macro.
  double ns = (double)cyc * 25.0;
  printf("CODEC id=%d pred=%u cycles=%llu ns_per_token=%.0f\n", id, pred,
         (unsigned long long)cyc, ns);
  return 0;
}
