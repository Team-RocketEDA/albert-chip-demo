// tb_top.cpp — Verilator driver for the FULL model (Part B + protocol).
//
// 64 baked token ids (tv_embed_ids.hex, cycled) -> embed -> LOOP30 ->
// lm_head subset logits + argmax -> pred_out, done exactly once.
// Mirrors tb_loop_top_stitch Part B (X_30 = X_0+30 loopback integrity,
// last-row subset-logit oracle) PLUS the Part A loop protocol checks at
// the real demo geometry (one-hot tile_sel, 09 lane tables, layer 0..29
// monotonic + coverage, theta_req==0 always, stall freeze/resume on an
// idle OLP lane, mid-run decoy-ignore). The S=2/H=8 mini-proxy was
// retired: the tiles assume full-dim geometry there (2300 clustered
// Verilator lints vs zero at full dims), so the proxy could never test
// the real design; these checks run at S=64/H=576 instead.
// Taps are wrapper outputs in tb_top.sv so Verilator keeps the cones.
// Traced to waves_top.fst.
//
// Run from the repo root:  make -C src/sim_verilator top
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "Vtb_top.h"
#include "Vtb_top___024root.h"
#include "verilated.h"
#include "verilated_fst_c.h"

static vluint64_t sim_time = 0;
static Vtb_top *top;
static VerilatedFstC *tfp;
static int errs = 0;
static const int S = 64, H = 576, N = S * H;

static void tick() {
  top->clk = 0; top->eval(); tfp->dump(sim_time++);
  top->clk = 1; top->eval(); tfp->dump(sim_time++);
}

// ---- protocol monitor (Part A at full dims) ----
static bool mon_on = false;      // strict checks while the loop runs
static bool loop_started = false;
static bool loop_finished = false;
static int last_layer = -1;
static int layers_seen[30] = {0};
static int phase_hist[4] = {0};

static int onehot_idx(int sel) {
  if (sel == 1) return 0;
  if (sel == 2) return 1;
  if (sel == 4) return 2;
  if (sel == 8) return 3;
  return -1;
}

static void mon_sample() {
  if (top->tap_theta_req) {
    printf("FAIL P: theta_req high (weight fetch!)\n"); errs++; mon_on = false; return;
  }
  if (!mon_on) return;
  int sel = top->tap_tile_sel;
  if (onehot_idx(sel) < 0) {
    printf("FAIL P: tile_sel=%d not one-hot (phase overlap?)\n", sel);
    errs++; mon_on = false; return;
  }
  switch (sel) {
    case 1: if (top->tap_ilp != 0x03 || top->tap_olp != 0x1F) {
      printf("FAIL P: p0 lanes ilp=%x olp=%x\n", top->tap_ilp, top->tap_olp);
      errs++; mon_on = false; return; } break;
    case 2: if (top->tap_ilp != 0x03 || top->tap_olp != 0x07) {
      printf("FAIL P: p1 lanes ilp=%x olp=%x\n", top->tap_ilp, top->tap_olp);
      errs++; mon_on = false; return; } break;
    case 4: if (top->tap_ilp != 0x03 || top->tap_olp != 0x3F) {
      printf("FAIL P: p2 lanes ilp=%x olp=%x\n", top->tap_ilp, top->tap_olp);
      errs++; mon_on = false; return; } break;
    case 8: if (top->tap_ilp != 0x3F || top->tap_olp != 0x03) {
      printf("FAIL P: p3 lanes ilp=%x olp=%x\n", top->tap_ilp, top->tap_olp);
      errs++; mon_on = false; return; } break;
  }
  phase_hist[onehot_idx(sel)]++;
  int layer = top->tap_layer_idx;
  if (layer < 0 || layer > 29) {
    printf("FAIL P: layer_idx=%d out of range\n", layer);
    errs++; mon_on = false; return;
  }
  if (layer != last_layer) {
    if (last_layer != -1 && layer != last_layer + 1) {
      printf("FAIL P: layer jump %d -> %d\n", last_layer, layer);
      errs++; mon_on = false; return;
    }
    last_layer = layer;
    layers_seen[layer] = 1;
  }
  if (top->tap_layer_done) loop_finished = true;
}

// Idle OLP lane 1 never sees traffic: forcing its count full stalls the
// FSM exactly like the iverilog force on olp_full. Path fixed up from
// the generated header if Verilator renames the generate scope.
static void olp1_set_full(bool full) {
  top->rootp->tb_top__DOT__u_dut__DOT__u_loop__DOT__olp_lanes__BRA__1__KET____DOT__u_lane__DOT__count_q
    = full ? 8 : 0;
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
  tfp = new VerilatedFstC;
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
  tick(); tick(); tick(); tick();
  top->rst_n = 1;
  tick(); tick();

  // Push 64 ids, one per row (lane 0), waiting ids_ready each time.
  mon_on = false;
  for (int rr = 0; rr < 64; rr++) {
    int cyc = 0;
    while (!top->tap_ids_ready && cyc < 10000) { tick(); mon_sample(); cyc++; }
    if (!top->tap_ids_ready) {
      printf("FAIL B: ids_ready never came (row %d)\n", rr); errs++; break;
    }
    top->ids_in[0] = (uint32_t)(ids8[rr % 8] & 0xFFFF);
    top->ids_valid = 1;
    tick(); mon_sample(); tick(); mon_sample();
    top->ids_valid = 0;
  }
  if (errs == 0) printf("phaseB pushed 64 ids PASS\n");

  // Wait for the embed frame, then arm the strict protocol monitor.
  int cyc = 0;
  while (cyc < 300000 && !top->tap_x0_valid) { tick(); mon_sample(); cyc++; }
  if (!top->tap_x0_valid) {
    printf("FAIL B: x0_valid never came\n"); errs++;
  } else printf("phaseB X0 valid after %d cyc PASS\n", cyc);
  mon_on = true;
  loop_started = true;

  // Run to layer 3, then stall freeze/resume on idle OLP lane 1.
  cyc = 0;
  while (cyc < 200000 && top->tap_layer_idx < 3 && !loop_finished) {
    tick(); mon_sample(); cyc++;
  }
  if (top->tap_layer_idx < 3) {
    printf("FAIL P: never reached layer 3\n"); errs++;
  } else {
    olp1_set_full(true);
    tick(); mon_sample(); tick(); mon_sample();
    int fr_layer = top->tap_layer_idx, fr_sel = top->tap_tile_sel;
    for (int i = 0; i < 20; i++) { tick(); mon_sample(); }
    if (top->tap_layer_idx != fr_layer || top->tap_tile_sel != fr_sel)
      printf("FAIL P: no stall (layer %d->%d sel %d->%d)\n",
             fr_layer, (int)top->tap_layer_idx, fr_sel, (int)top->tap_tile_sel), errs++;
    else printf("phaseP stall freeze (20cyc, layer %d) PASS\n", fr_layer);
    if (top->tap_theta_req) { printf("FAIL P: theta_req during stall\n"); errs++; }
    olp1_set_full(false);
  }

  // Run to layer 5, then a mid-run decoy ids push must be ignored.
  cyc = 0;
  while (cyc < 200000 && top->tap_layer_idx < 5 && !loop_finished) {
    tick(); mon_sample(); cyc++;
  }
  for (int w = 0; w < 32; w++) top->ids_in[w] = 0xFFFFFFFF;
  top->ids_valid = 1;
  tick(); mon_sample(); tick(); mon_sample();
  top->ids_valid = 0;
  top->ids_in[0] = 0;

  // Wait for the 30x loop.
  cyc = 0;
  while (cyc < 200000 && !top->tap_layer_done) { tick(); mon_sample(); cyc++; }
  if (!top->tap_layer_done) {
    printf("FAIL B: loop layer_done never came\n"); errs++;
  } else printf("phaseB LOOP30 done after %d cyc PASS\n", cyc);
  for (int i = 0; i < 5; i++) { tick(); mon_sample(); }
  mon_on = false;

  // Protocol coverage: layers + phases observed.
  {
    int bad = 0;
    for (int q = 0; q < 30; q++)
      if (!layers_seen[q]) { printf("FAIL P: layer %d never observed\n", q); bad++; }
    for (int q = 0; q < 4; q++)
      if (!phase_hist[q]) { printf("FAIL P: phase %d never observed\n", q); bad++; }
    if (bad == 0) printf("phaseP layers 0..29 + phases p0..p3 all observed PASS\n");
    errs += bad;
  }

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
    tick(); mon_sample(); cyc++;
    if (top->done && !prev) pulses++;
    prev = top->done;
  }
  for (int i = 0; i < 20; i++) { tick(); mon_sample(); }
  if (top->done) pulses++;
  if (pulses != 1) {
    printf("FAIL B: head done pulses=%d want 1\n", pulses); errs++;
  } else printf("phaseB head done exactly-once PASS\n");
  if (errs == 0) {
    if ((int)top->pred_out != b_exp) {
      printf("FAIL B: pred=%d want=%d\n", (int)top->pred_out, b_exp); errs++;
    } else printf("phaseB pred=%d matches oracle PASS\n", (int)top->pred_out);
  }

  if (errs == 0) printf("TOP_VLT PASS (ids->pred full model + protocol)\n");
  else printf("TOP_VLT FAIL (%d errs)\n", errs);
  tfp->close();
  return errs == 0 ? 0 : 1;
}
