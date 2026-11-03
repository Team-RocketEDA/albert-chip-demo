// tb_top.cpp — Verilator driver for the FULL model (Part B protocol).
//
// 64 baked token ids (tv_embed_ids.hex, cycled) -> embed -> LOOP30 ->
// lm_head subset logits + argmax -> pred_out, done exactly once.
// Mirrors tb_loop_top_stitch Part B: X_30 must equal X_0+30 per byte
// (loopback integrity), last row feeds a C++ subset-logit oracle
// (wlm_subset16.hex) whose argmax must equal pred_out. The taps
// (ids_ready/x0_valid/layer_done/X0/X_30) are wrapper outputs in
// tb_top.sv so Verilator keeps the cones. Traced to waves_top.fst.
//
// Run from the repo root:  make -C src/sim_verilator top
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_fst_c.h"

static vluint64_t sim_time = 0;
static const int S = 64, H = 576, N = S * H;

static void tick(Vtb_top *top, VerilatedFstC *tfp) {
  top->clk = 0; top->eval(); tfp->dump(sim_time++);
  top->clk = 1; top->eval(); tfp->dump(sim_time++);
}

static std::vector<long> load_hex(const char *path, size_t want, int base = 16) {
  std::vector<long> out;
  std::ifstream f(path);
  std::string line;
  while (std::getline(f, line)) {
    if (line.empty()) continue;
    long v = std::stol(line, nullptr, base);
    out.push_back(v);
  }
  if (out.size() != want) {
    printf("FATAL: %s has %zu entries, want %zu\n", path, out.size(), want);
    exit(2);
  }
  return out;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_top *top = new Vtb_top;
  VerilatedFstC *tfp = new VerilatedFstC;
  Verilated::traceEverOn(true);
  top->trace(tfp, 99);
  tfp->open("src/sim_verilator/waves_top.fst");
  std::vector<long> ids8 = load_hex("weights/bake/tv_embed_ids.hex", 8);
  std::vector<long> wmem = load_hex("src/tb/lm_head_stitch/wlm_subset16.hex", 16 * H);
  for (long &v : wmem) { if (v > 127) v -= 256; }
  printf("[top] baked ids + subset weights loaded\n");

  top->start = 0; top->ids_valid = 0;
  for (int w = 0; w < 32; w++) top->ids_in[w] = 0;
  top->rst_n = 0;
  tick(top, tfp); tick(top, tfp); tick(top, tfp); tick(top, tfp);
  top->rst_n = 1;
  tick(top, tfp); tick(top, tfp);

  int errs = 0;
  // Push 64 ids, one per row (lane 0), waiting ids_ready each time.
  for (int rr = 0; rr < 64; rr++) {
    int cyc = 0;
    while (!top->tap_ids_ready && cyc < 10000) {
      tick(top, tfp); cyc++;
    }
    if (!top->tap_ids_ready) {
      printf("FAIL B: ids_ready never came (row %d)\n", rr); errs++; break;
    }
    top->ids_in[0] = (uint32_t)(ids8[rr % 8] & 0xFFFF);
    top->ids_valid = 1;
    tick(top, tfp); tick(top, tfp);
    top->ids_valid = 0;
  }
  if (errs == 0) printf("phaseB pushed 64 ids PASS\n");

  // Wait for the embed frame.
  int cyc = 0;
  while (cyc < 300000 && !top->tap_x0_valid) {
    tick(top, tfp); cyc++;
  }
  if (!top->tap_x0_valid) {
    printf("FAIL B: x0_valid never came\n"); errs++;
  } else printf("phaseB X0 valid after %d cyc PASS\n", cyc);

  // Wait for the 30x loop.
  cyc = 0;
  while (cyc < 100000 && !top->tap_layer_done) {
    tick(top, tfp); cyc++;
  }
  if (!top->tap_layer_done) {
    printf("FAIL B: loop layer_done never came\n"); errs++;
  } else printf("phaseB LOOP30 done after %d cyc PASS\n", cyc);
  for (int i = 0; i < 5; i++) tick(top, tfp);

  // X_30 = X_0 + 30 per byte; last-row subset-logit oracle + argmax.
  int b_exp = -1;
  if (errs == 0) {
    auto &x0 = top->tap_x0;
    auto &x3 = top->tap_x30;
    int xerrs = 0;
    for (int b = 0; b < N; b++) {
      uint8_t xb = (x0[b / 4] >> (8 * (b % 4))) & 0xFF;
      uint8_t got = (x3[b / 4] >> (8 * (b % 4))) & 0xFF;
      if (got != (uint8_t)(xb + 30)) {
        if (xerrs < 8)
          printf("FAIL B: X30 byte%d=%02x want X0+30=%02x\n", b, got, (uint8_t)(xb + 30));
        xerrs++;
      }
    }
    if (xerrs == 0) printf("phaseB X_30 = X_0+30 full-frame PASS\n");
    errs += xerrs;
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
    tick(top, tfp); cyc++;
    if (top->done && !prev) pulses++;
    prev = top->done;
  }
  for (int i = 0; i < 20; i++) tick(top, tfp);
  if (top->done) pulses++;
  if (pulses != 1) {
    printf("FAIL B: head done pulses=%d want 1\n", pulses); errs++;
  } else printf("phaseB head done exactly-once PASS\n");
  if (errs == 0) {
    if ((int)top->pred_out != b_exp) {
      printf("FAIL B: pred=%d want=%d\n", (int)top->pred_out, b_exp); errs++;
    } else printf("phaseB pred=%d matches oracle PASS\n", (int)top->pred_out);
  }

  if (errs == 0) printf("TOP_VLT PASS (ids->pred full model)\n");
  else printf("TOP_VLT FAIL (%d errs)\n", errs);
  tfp->close();
  return errs == 0 ? 0 : 1;
}
