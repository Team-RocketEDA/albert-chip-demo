// tb_inproj.cpp — Verilator driver: activation rows in, Q|K|V bytes out.
//
// Three frames, mirroring tb_inproj_tile_stitch: frame f drives act row
// tv_{q,k,v}_act.hex and anchors third f (Q/K/V) to the first-8 baked
// s32 goldens. Every frame checks all 960 accum entries EXACTLY (s32,
// mod-2^32, via hierarchical u_accum.mem) plus all 960 y_out bytes
// (requant y=clip(dot) at cfg_scale=256/cfg_zero=0), tok_ready drop
// while busy, spurious tok_valid ignored, and exactly one y_valid
// pulse. Independent C++ oracle recomputes every dot from the baked
// weight images. Traced to waves_inproj.fst.
//
// Run from the repo root:  make -C src/sim_verilator inproj
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "Vtb_inproj.h"
#include "Vtb_inproj___024root.h"
#include "verilated.h"
#include "verilated_fst_c.h"

static vluint64_t sim_time = 0;

static void tick(Vtb_inproj *top, VerilatedFstC *tfp) {
  top->clk = 0; top->eval(); tfp->dump(sim_time++);
  top->clk = 1; top->eval(); tfp->dump(sim_time++);
}

// One hex byte per line -> bytes.
static std::vector<int8_t> load_bytes(const char *path, size_t want) {
  std::vector<int8_t> out;
  std::ifstream f(path);
  std::string line;
  while (std::getline(f, line)) {
    if (line.empty()) continue;
    long v = std::stol(line, nullptr, 16);
    if (v > 127) v -= 256;
    out.push_back((int8_t)v);
  }
  if (out.size() != want) {
    printf("FATAL: %s has %zu bytes, want %zu\n", path, out.size(), want);
    exit(2);
  }
  return out;
}

// One 32-bit hex word per line -> signed dots.
static std::vector<int32_t> load_dots(const char *path, size_t want) {
  std::vector<int32_t> out;
  std::ifstream f(path);
  std::string line;
  while (std::getline(f, line)) {
    if (line.empty()) continue;
    out.push_back((int32_t)std::stoul(line, nullptr, 16));
  }
  if (out.size() != want) {
    printf("FATAL: %s has %zu dots, want %zu\n", path, out.size(), want);
    exit(2);
  }
  return out;
}

static int8_t clip8(int32_t v) {
  if (v > 127) return 127;
  if (v < -128) return -128;
  return (int8_t)v;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_inproj *top = new Vtb_inproj;
  VerilatedFstC *tfp = new VerilatedFstC;
  Verilated::traceEverOn(true);
  top->trace(tfp, 99);
  tfp->open("src/sim_verilator/waves_inproj.fst");

  const char *acts[3] = {"weights/bake/tv_q_act.hex", "weights/bake/tv_k_act.hex",
                         "weights/bake/tv_v_act.hex"};
  const char *gold[3] = {"weights/bake/tv_q_golden.hex", "weights/bake/tv_k_golden.hex",
                         "weights/bake/tv_v_golden.hex"};
  std::vector<int8_t> Wq = load_bytes("weights/bake/layer0_q_proj.hex", 576 * 576);
  std::vector<int8_t> Wk = load_bytes("weights/bake/layer0_k_proj.hex", 192 * 576);
  std::vector<int8_t> Wv = load_bytes("weights/bake/layer0_v_proj.hex", 192 * 576);

  top->rst_n = 0; top->tok_valid = 0;
  top->cfg_scale = 256; top->cfg_zero = 0;
  tick(top, tfp); tick(top, tfp);
  top->rst_n = 1;
  tick(top, tfp);

  int errs = 0;
  // Micro-trace mode: `Vtb_inproj trace` prints (state,f,j,hold,psum,
  // acc_r) every MCAP/AWR tick until the first output completes.
  // Fog map: state 3=MSET 4=MCAP 5=AWR.
  if (argc > 1 && std::string(argv[1]) == "trace") {
  for (int w = 0; w < 144; w++) {
    uint32_t word = 0;
    for (int b = 0; b < 4; b++)
      word |= (uint32_t)(uint8_t)load_bytes(acts[0], 576)[w * 4 + b] << (8 * b);
    top->tok_in[w] = word;
  }
  {
    int guard = 0;
    while (!top->tok_ready && guard < 1000) { tick(top, tfp); guard++; }
    top->tok_valid = 1; tick(top, tfp); top->tok_valid = 0;
    auto *r = top->rootp;
    for (int t = 0; t < 400 && (int)r->tb_inproj__DOT__u_dut__DOT__j_q == 0; t++) {
      unsigned st = r->tb_inproj__DOT__u_dut__DOT__state_q;
      if (st == 4 || st == 5)
        printf("t=%d st=%u f=%u j=%u hold=%d acc_r=%d\n", t, st,
               (unsigned)r->tb_inproj__DOT__u_dut__DOT__f_q,
               (unsigned)r->tb_inproj__DOT__u_dut__DOT__j_q,
               (int32_t)r->tb_inproj__DOT__u_dut__DOT__hold_q,
               (int32_t)r->tb_inproj__DOT__u_dut__DOT__u_mac__DOT__acc_r);
      tick(top, tfp);
      if ((int)r->tb_inproj__DOT__u_dut__DOT__j_q != 0) break;
    }
    printf("accum[0]=%d\n",
           (int32_t)r->tb_inproj__DOT__u_dut__DOT__u_accum__DOT__mem[0]);
    tfp->close();
    return 0;
  }
  }
  for (int f = 0; f < 3; f++) {
    std::vector<int8_t> act = load_bytes(acts[f], 576);
    std::vector<int32_t> g = load_dots(gold[f], 8);

    // Oracle: all 960 exact s32 dots + requanted bytes from this act row.
    std::vector<int32_t> exp_acc(960);
    std::vector<int8_t> exp_y(960);
    for (int j = 0; j < 960; j++) {
      const int8_t *W = (j < 576) ? Wq.data() + (size_t)j * 576
                      : (j < 768) ? Wk.data() + (size_t)(j - 576) * 576
                                  : Wv.data() + (size_t)(j - 768) * 576;
      uint32_t acc = 0;
      for (int c = 0; c < 576; c++)
        acc += (uint32_t)((int32_t)act[c] * (int32_t)W[c]);
      exp_acc[j] = (int32_t)acc;
      exp_y[j] = clip8((int32_t)acc);
    }
    // Anchor third f's first-8 dots to the baked golden.
    int base = (f == 0) ? 0 : (f == 1) ? 576 : 768;
    for (int j = 0; j < 8; j++)
      if (exp_acc[base + j] != g[j]) {
        printf("FAIL frame%d: oracle dot[%d]=%d vs golden %d\n",
               f, base + j, exp_acc[base + j], g[j]);
        errs++;
      }

    // Present the row, wait ready, single-cycle tok_valid.
    for (int w = 0; w < 144; w++) {
      uint32_t word = 0;
      for (int b = 0; b < 4; b++)
        word |= (uint32_t)(uint8_t)act[w * 4 + b] << (8 * b);
      top->tok_in[w] = word;
    }
    int guard = 0;
    while (!top->tok_ready && guard < 1000) { tick(top, tfp); guard++; }
    if (!top->tok_ready) { printf("FAIL frame%d: ready never rose\n", f); errs++; continue; }
    top->tok_valid = 1;
    tick(top, tfp);
    top->tok_valid = 0;

    // Busy: ready must drop; a spurious tok_valid must be ignored.
    for (int i = 0; i < 50; i++) tick(top, tfp);
    if (top->tok_ready) { printf("FAIL frame%d: ready did not drop while busy\n", f); errs++; }
    top->tok_valid = 1;
    tick(top, tfp);
    top->tok_valid = 0;

    // Run to completion; y_valid must pulse exactly once.
    int pulses = 0;
    guard = 0;
    while (!top->tok_ready && guard < 500000) {
      tick(top, tfp);
      if (top->y_valid) pulses++;
      guard++;
    }
    if (!top->tok_ready) { printf("FAIL frame%d: frame never completed\n", f); errs++; continue; }
    if (pulses != 1) { printf("FAIL frame%d: y_valid pulses=%d want 1\n", f, pulses); errs++; }

    // Accum: all 960 exact s32 (wraps mod-2^32, never saturates).
    int bad = 0;
    for (int j = 0; j < 960; j++) {
      int32_t got = (int32_t)top->rootp->tb_inproj__DOT__u_dut__DOT__u_accum__DOT__mem[j];
      if (got != exp_acc[j]) {
        if (bad < 5) printf("FAIL frame%d accum[%d]: got=%d want=%d\n", f, j, got, exp_acc[j]);
        bad++;
      }
    }
    if (bad) errs += bad;
    // y_out: all 960 bytes requanted (saturation lives here only).
    bad = 0;
    for (int j = 0; j < 960; j++) {
      int8_t got = (int8_t)((top->y_out[j / 4] >> (8 * (j % 4))) & 0xFF);
      if (got != exp_y[j]) {
        if (bad < 5) printf("FAIL frame%d y_out[%d]: got=%d want=%d\n", f, j, got, exp_y[j]);
        bad++;
      }
    }
    if (bad) errs += bad;
    printf("[inproj] frame%d (%s): accum+y exact, y_valid x1\n", f,
           f == 0 ? "Q third" : f == 1 ? "K third" : "V third");
  }

  // ---- S=2 frame: both rows act_q, exercises the RCAP row-advance.
  {
    std::vector<int8_t> act = load_bytes(acts[0], 576);
    for (int w = 0; w < 288; w++) {
      uint32_t word = 0;
      for (int b = 0; b < 4; b++)
        word |= (uint32_t)(uint8_t)act[(w * 4 + b) % 576] << (8 * b);
      top->tok_in2[w] = word;
    }
    int guard = 0;
    while (!top->tok_ready2 && guard < 1000) { tick(top, tfp); guard++; }
    if (!top->tok_ready2) { printf("FAIL S=2: ready never rose\n"); errs++; }
    else {
      top->tok_valid2 = 1;
      tick(top, tfp);
      top->tok_valid2 = 0;
      int pulses = 0;
      guard = 0;
      while (!top->tok_ready2 && guard < 1000000) {
        tick(top, tfp);
        if (top->y_valid2) pulses++;
        guard++;
      }
      if (!top->tok_ready2) { printf("FAIL S=2: frame never completed\n"); errs++; }
      if (pulses != 1) { printf("FAIL S=2: y_valid pulses=%d want 1\n", pulses); errs++; }
      // accum holds the last row; both packed rows must match the oracle.
      std::vector<int32_t> exp_acc(960);
      std::vector<int8_t> exp_y(960);
      for (int j = 0; j < 960; j++) {
        const int8_t *W = (j < 576) ? Wq.data() + (size_t)j * 576
                        : (j < 768) ? Wk.data() + (size_t)(j - 576) * 576
                                    : Wv.data() + (size_t)(j - 768) * 576;
        uint32_t acc = 0;
        for (int c = 0; c < 576; c++)
          acc += (uint32_t)((int32_t)act[c] * (int32_t)W[c]);
        exp_acc[j] = (int32_t)acc;
        exp_y[j] = clip8((int32_t)acc);
      }
      int bad = 0;
      for (int j = 0; j < 960; j++) {
        int32_t got = (int32_t)top->rootp->tb_inproj__DOT__u_dut2__DOT__u_accum__DOT__mem[j];
        if (got != exp_acc[j]) {
          if (bad < 5) printf("FAIL S=2 accum[%d]: got=%d want=%d\n", j, got, exp_acc[j]);
          bad++;
        }
      }
      if (bad) errs += bad;
      bad = 0;
      for (int r = 0; r < 2; r++)
        for (int j = 0; j < 960; j++) {
          int k = r * 960 + j;
          int8_t got = (int8_t)((top->y_out2[k / 4] >> (8 * (k % 4))) & 0xFF);
          if (got != exp_y[j]) {
            if (bad < 5) printf("FAIL S=2 y_out row%d[%d]: got=%d want=%d\n", r, j, got, exp_y[j]);
            bad++;
          }
        }
      if (bad) errs += bad;
      else printf("[inproj] S=2 frame: 2 rows x 960 bytes exact, y_valid x1\n");
    }
  }
  // Readable snapshot: first 8 bytes of each third from the last frame.
  printf("y[0..7]   =");
  for (int j = 0; j < 8; j++)
    printf(" %d", (int8_t)((top->y_out[j / 4] >> (8 * (j % 4))) & 0xFF));
  printf("\ny[576..583]=");
  for (int j = 576; j < 584; j++)
    printf(" %d", (int8_t)((top->y_out[j / 4] >> (8 * (j % 4))) & 0xFF));
  printf("\ny[768..775]=");
  for (int j = 768; j < 776; j++)
    printf(" %d", (int8_t)((top->y_out[j / 4] >> (8 * (j % 4))) & 0xFF));
  printf("\n");
  if (errs == 0) printf("INPROJ_VLT PASS (4 frames: 3xS=1 + S=2 rows, dots + bytes exact)\n");
  else printf("INPROJ_VLT FAIL (%d errs)\n", errs);
  tfp->close();
  return errs == 0 ? 0 : 1;
}
