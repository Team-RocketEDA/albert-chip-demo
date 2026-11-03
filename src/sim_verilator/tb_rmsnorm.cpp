// tb_rmsnorm.cpp — readable Verilator driver: one baked frame in/out.
//
// Streams a full 576-lane RMSNorm frame (baked input x + baked gamma,
// resid = 0, exactly like the iverilog phase-A check), collects the 576
// y_valid outputs, and prints the first 8 lanes as
//   lane | x_in | gamma | y_out | golden | err
// so you can SEE vectors go in and normalized vectors come out. Anything
// over 3 LSB vs the baked golden is a MISMATCH. Waveform: waves_rmsnorm.fst
// (add `x`, `gamma`, `y`, `y_valid` in Surfer).
//
// Run from anywhere in the repo:  make -C src/sim_verilator rmsnorm
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "Vtb_rmsnorm.h"
#include "verilated.h"
#include "verilated_fst_c.h"

static vluint64_t sim_time = 0;
static const int D = 576;
static const int TOL = 3;

static void tick(Vtb_rmsnorm *top, VerilatedFstC *tfp) {
  top->clk = 0; top->eval(); tfp->dump(sim_time++);
  top->clk = 1; top->eval(); tfp->dump(sim_time++);
}

static std::vector<int> load_hex4(const char *path) {
  std::vector<int> out;
  std::string line;
  std::ifstream f(path);
  while (std::getline(f, line)) {
    if (line.empty()) continue;
    int v = (int)std::stoul(line, nullptr, 16);
    if (v & 0x8000) v -= 0x10000;  // Q8.8 signed
    out.push_back(v);
  }
  return out;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_rmsnorm *top = new Vtb_rmsnorm;
  VerilatedFstC *tfp = new VerilatedFstC;
  Verilated::traceEverOn(true);
  top->trace(tfp, 99);
  tfp->open("src/sim_verilator/waves_rmsnorm.fst");

  std::vector<int> sx = load_hex4("src/tb/rmsnorm_d/stim_x.hex");
  std::vector<int> sg = load_hex4("src/tb/rmsnorm_d/stim_g.hex");
  std::vector<int> golden = load_hex4("weights/bake/tv_rmsnorm_golden.hex");
  printf("[rmsnorm] frame: %zu x lanes, %zu gamma lanes, %zu golden lanes\n",
         sx.size(), sg.size(), golden.size());

  // Reset, then one idle clock (the DUT resets into end-of-frame).
  top->rst_n = 0; top->x = 0; top->resid = 0; top->gamma = 0;
  tick(top, tfp); tick(top, tfp);
  top->rst_n = 1;
  tick(top, tfp);

  // LOAD: one (x, 0, gamma) lane per clock for D lanes.
  for (int i = 0; i < D; i++) {
    top->x = sx[i] & 0xFFFF; top->resid = 0; top->gamma = sg[i] & 0xFFFF;
    tick(top, tfp);
  }
  // CALC/NR/DENORM + OUT: park inputs, collect 576 y_valid pulses.
  top->x = 0; top->resid = 0; top->gamma = 0;
  std::vector<int> got;
  for (int c = 0; c < 3000 && (int)got.size() < D; c++) {
    tick(top, tfp);
    if (top->y_valid) {
      int y = top->y;
      if (y & 0x8000) y -= 0x10000;
      got.push_back(y);
    }
  }

  int errs = 0;
  if ((int)got.size() != D)
    { printf("FAIL: y_valid pulses=%zu want=%d\n", got.size(), D); errs += 1000; }
  printf(" lane |    x_in |  gamma |  y_out | golden | err\n");
  for (int i = 0; i < D && i < (int)got.size(); i++) {
    int err = std::abs(got[i] - golden[i]);
    if (err > TOL) errs++;
    if (i < 8 || err > TOL)
      printf(" %4d | %7d | %6d | %6d | %6d | %d%s\n",
             i, sx[i], sg[i], got[i], golden[i], err,
             err > TOL ? "  MISMATCH" : (i < 8 ? "  ok" : ""));
  }
  if ((int)got.size() > 8) printf(" .. %d more lanes checked silently\n", (int)got.size() - 8);

  // Zero frame must come back all-zero (sanity, mirrors iverilog phase C).
  top->rst_n = 0; tick(top, tfp); tick(top, tfp); top->rst_n = 1; tick(top, tfp);
  for (int i = 0; i < D; i++) { top->x = 0; top->resid = 0; top->gamma = 0; tick(top, tfp); }
  int zpulses = 0, zbad = 0;
  for (int c = 0; c < 3000 && zpulses < D; c++) {
    tick(top, tfp);
    if (top->y_valid) { zpulses++; if (top->y != 0) zbad++; }
  }
  printf("zero frame: %d pulses, %d nonzero -> %s\n",
         zpulses, zbad, (zpulses == D && zbad == 0) ? "ok" : "MISMATCH");
  if (zpulses != D || zbad) errs++;

  if (errs == 0) printf("RMSNORM_VLT PASS (%d lanes, tol=%d LSB)\n", D, TOL);
  else printf("RMSNORM_VLT FAIL (%d errs)\n", errs);
  tfp->close();
  return errs == 0 ? 0 : 1;
}
