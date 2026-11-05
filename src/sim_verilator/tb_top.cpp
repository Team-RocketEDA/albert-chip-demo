// tb_top.cpp — Verilator driver for the FULL etched model.
//
// 64 prompt ids (baked tv_embed_ids.hex cycled, or PROMPT_IDS="12 345.."
// custom ids, cycled) -> embed -> 30-deep ETCHED STACK ->
// lm_head subset logits + argmax -> pred_out, done exactly once.
// The last-row subset-logit oracle (recomputed here from the X30 frame
// and the baked subset weights) must match the DUT's pred_out.
//
// NOTRACE=1 skips FST tracing (the stack run is tens of millions of
// cycles; tracing it would bury the disk). Run from the repo root:
//   make -C src/sim_verilator top
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "Vtb_top.h"
#include "Vtb_top___024root.h"
#include "verilated.h"
#include "verilated_fst_c.h"

static vluint64_t sim_time = 0;
static Vtb_top *top;
static VerilatedFstC *tfp = nullptr;
static int errs = 0;
static const int S = 64, H = 576, N = S * H;

static void tick() {
  top->clk = 0; top->eval(); if (tfp) tfp->dump(sim_time++);
  top->clk = 1; top->eval(); if (tfp) tfp->dump(sim_time++);
}

static std::vector<long> load_hex(const char *path, size_t want) {
  std::vector<long> out;
  std::ifstream f(path);
  std::string line;
  while (std::getline(f, line)) {
    if (line.empty()) continue;
    out.push_back(std::stol(line, nullptr, 16));
  }
  if (out.size() != want) {
    printf("FATAL: %s has %zu entries, want %zu\n", path, out.size(), want);
    exit(2);
  }
  return out;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vtb_top;
  bool tracing = !std::getenv("NOTRACE");
  if (tracing) {
    Verilated::traceEverOn(true);
    tfp = new VerilatedFstC;
    top->trace(tfp, 99);
    tfp->open("src/sim_verilator/waves_top.fst");
  } else {
    printf("[top] tracing off (NOTRACE=1)\n");
  }
  std::vector<long> ids8 = load_hex("weights/bake/tv_embed_ids.hex", 8);
  // PROMPT_IDS="12 345 67": custom prompt ids (cycled to 64 rows) for the
  // talking-bot test. Unset = baked default path, bit-for-bit as qualified.
  if (const char *prompt = std::getenv("PROMPT_IDS")) {
    std::vector<long> custom;
    std::istringstream words(prompt);
    long v;
    while (words >> v) custom.push_back(v & 0xFFFF);
    if (!custom.empty()) {
      ids8 = custom;
      printf("[top] custom prompt ids (%zu) via PROMPT_IDS\n", custom.size());
    }
  }
  std::vector<long> wmem = load_hex("src/tb/lm_head_stitch/wlm_subset16.hex", 16 * H);
  for (long &v : wmem) { if (v > 127) v -= 256; }
  printf("[top] baked ids + subset weights loaded\n");

  top->start = 0; top->ids_valid = 0;
  for (int w = 0; w < 32; w++) top->ids_in[w] = 0;
  top->rst_n = 0;
  tick(); tick(); tick(); tick();
  top->rst_n = 1;
  tick(); tick();

  // Push 64 ids, one per row (lane 0), waiting ids_ready each time.
  for (int rr = 0; rr < 64; rr++) {
    int cyc = 0;
    while (!top->tap_ids_ready && cyc < 10000) { tick(); cyc++; }
    if (!top->tap_ids_ready) {
      printf("FAIL B: ids_ready never came (row %d)\n", rr); errs++; break;
    }
    top->ids_in[0] = (uint32_t)(ids8[rr % ids8.size()] & 0xFFFF);
    top->ids_valid = 1;
    tick(); tick();
    top->ids_valid = 0;
  }
  if (errs == 0) printf("phaseB pushed 64 ids PASS\n");

  // Wait for the embed frame.
  int cyc = 0;
  while (cyc < 300000 && !top->tap_x0_valid) { tick(); cyc++; }
  if (!top->tap_x0_valid) {
    printf("FAIL B: x0_valid never came\n"); errs++;
  } else printf("phaseB X0 valid after %d cyc PASS\n", cyc);

  // Wait for the 30-deep etched stack frame, with heartbeat.
  cyc = 0;
  int next_beat = 10000000;
  while (cyc < 500000000 && !top->tap_layer_done) {
    tick(); cyc++;
    if (cyc == next_beat) {
      printf("[top] ... %d cycles, stack running\n", cyc);
      next_beat += 10000000;
    }
  }
  if (!top->tap_layer_done) {
    printf("FAIL B: stack layer_done never came\n"); errs++;
  } else printf("phaseB STACK30 done after %d cyc PASS\n", cyc);
  for (int i = 0; i < 20; i++) { tick(); }

  // Last-row subset-logit oracle + argmax.
  int b_exp = -1;
  if (errs == 0) {
    auto &x3 = top->tap_x30;
    int64_t blo[16] = {0};
    for (int kk = 0; kk < 16; kk++) {
      int64_t acc = 0;
      for (int bb = 0; bb < H; bb++) {
        int k = 63 * H + bb;
        int8_t xb = (int8_t)((x3[k / 4] >> (8 * (k % 4))) & 0xFF);
        acc += (int64_t)xb * (int64_t)wmem[kk * H + bb];
      }
      blo[kk] = (int32_t)(acc & 0xFFFFFFFF);
    }
    b_exp = 0;
    for (int kk = 1; kk < 16; kk++)
      if ((int32_t)blo[kk] > (int32_t)blo[b_exp]) b_exp = kk;
    printf("phaseB oracle argmax pred=%d logit=%08x\n", b_exp, (uint32_t)blo[b_exp]);
  }

  // Head done exactly once + pred match.
  cyc = 0;
  int pulses = 0, prev = 0;
  while (cyc < 2000 && pulses == 0) {
    tick(); cyc++;
    if (top->done && !prev) pulses++;
    prev = top->done;
  }
  for (int i = 0; i < 20; i++) { tick(); }
  if (top->done) pulses++;
  if (pulses != 1) {
    printf("FAIL B: head done pulses=%d want 1\n", pulses); errs++;
  } else printf("phaseB head done exactly-once PASS\n");
  if (errs == 0) {
    if ((int)top->pred_out != b_exp) {
      printf("FAIL B: pred=%d want=%d\n", (int)top->pred_out, b_exp); errs++;
    } else printf("phaseB pred=%d matches oracle PASS\n", (int)top->pred_out);
  }

  if (errs == 0) printf("TOP_VLT PASS (ids->pred etched stack + oracle)\n");
  else printf("TOP_VLT FAIL (%d errs)\n", errs);
  if (tfp) tfp->close();
  return errs == 0 ? 0 : 1;
}
