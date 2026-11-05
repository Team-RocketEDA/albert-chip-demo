// tb_chunk_equiv.cpp — Verilator driver: one activation row into the
// monolith and the 2-slice harness, then an exact 960-byte compare.
// Prints CHUNK_EQUIV PASS or FAIL lines (never silent on mismatch).
//
// Run from the repo root:  make -C src/sim_verilator chunk-equiv
#include <cstdint>
#include <cstdio>

#include "Vtb_chunk_equiv.h"
#include "verilated.h"

static vluint64_t sim_time = 0;
static Vtb_chunk_equiv *top;

static void tick() {
  top->clk = 0; top->eval(); sim_time++;
  top->clk = 1; top->eval(); sim_time++;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vtb_chunk_equiv;
  top->clk = 0;
  top->rst_n = 0;
  top->tok_valid = 0;
  top->cfg_scale = 256;
  top->cfg_zero = 0;
  for (int w = 0; w < 144; w++) {
    uint32_t word = 0;
    for (int b = 0; b < 4; b++) {
      int i = w * 4 + b;
      uint8_t by = (i < 576) ? (uint8_t)((i * 13 + 7) & 0xFF) : 0;
      word |= (uint32_t)by << (8 * b);
    }
    top->tok_in[w] = word;
  }
  for (int i = 0; i < 5; i++) tick();
  top->rst_n = 1;
  tick(); tick();
  top->tok_valid = 1;
  tick(); tick(); tick();
  top->tok_valid = 0;

  bool mv = false, cv = false;
  uint8_t got_m[960], got_c[960];
  for (int i = 0; i < 960; i++) got_m[i] = got_c[i] = 0;
  vluint64_t cyc = 0;
  while (!(mv && cv) && cyc < 1000000) {
    tick();
    cyc++;
    if (top->mono_v && !mv) {
      for (int i = 0; i < 960; i++)
        got_m[i] = (uint8_t)((top->mono_y[i / 4] >> (8 * (i % 4))) & 0xFF);
      mv = true;
    }
    if (top->chunk_v && !cv) {
      for (int i = 0; i < 960; i++)
        got_c[i] = (uint8_t)((top->chunk_y[i / 4] >> (8 * (i % 4))) & 0xFF);
      cv = true;
    }
  }
  if (!mv || !cv) {
    printf("CHUNK_EQUIV FAIL timeout mono=%d chunk=%d cyc=%llu\n", mv, cv,
           (unsigned long long)cyc);
    return 1;
  }
  int errs = 0;
  for (int i = 0; i < 960; i++) {
    if (got_m[i] != got_c[i]) {
      if (errs < 8)
        printf("CHUNK_EQUIV FAIL byte %d: mono=%02x chunk=%02x\n", i, got_m[i],
               got_c[i]);
      errs++;
    }
  }
  if (errs == 0) {
    printf("CHUNK_EQUIV PASS (960/960 bytes, cyc=%llu)\n",
           (unsigned long long)cyc);
    return 0;
  }
  printf("CHUNK_EQUIV FAIL errs=%d\n", errs);
  return 1;
}
