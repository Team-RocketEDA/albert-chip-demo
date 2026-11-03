// tb_embed.cpp — readable Verilator driver: input tokens, output vectors.
//
// For each baked test id: present the id, step the clock once (the LUT has
// 1-cycle registered latency), read back the 576-byte vector, compare it
// byte-for-byte against the baked golden, and print the id with the first
// 8 bytes so you can SEE tokens go in and vectors come out. Everything is
// also traced to waves_embed.fst — open it in Surfer and add `token_id`
// and `vec` to watch the lookup happen.
//
// Run from the repo root:  make -C src/sim_verilator embed
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "Vtb_embed.h"
#include "verilated.h"
#include "verilated_fst_c.h"

static vluint64_t sim_time = 0;

static void tick(Vtb_embed *top, VerilatedFstC *tfp) {
  top->clk = 0; top->eval(); tfp->dump(sim_time++);
  top->clk = 1; top->eval(); tfp->dump(sim_time++);
}

// One hex row (MSB-first number) -> 576 bytes, byte k = bits [8k+7:8k],
// i.e. parsed from the RIGHT end of the line.
static std::vector<uint8_t> parse_row(const std::string &line, int nbytes) {
  std::vector<uint8_t> out(nbytes, 0);
  int L = (int)line.size();
  for (int k = 0; k < nbytes; k++) {
    int hi = L - 1 - 2 * k;
    if (hi < 1) break;
    out[k] = (uint8_t)std::stoul(line.substr(hi - 1, 2), nullptr, 16);
  }
  return out;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_embed *top = new Vtb_embed;
  VerilatedFstC *tfp = new VerilatedFstC;
  Verilated::traceEverOn(true);
  top->trace(tfp, 99);
  tfp->open("src/sim_verilator/waves_embed.fst");

  // Load stimulus: 8 test token ids + 8 golden 576-byte vectors.
  std::vector<int> ids;
  std::string line;
  std::ifstream fi("src/tb/embed_lut/ids_full.hex");
  while (std::getline(fi, line)) if (!line.empty())
    ids.push_back((int)std::stoul(line, nullptr, 16));
  std::vector<std::vector<uint8_t>> golden;
  std::ifstream fg("src/tb/embed_lut/exp_full.hex");
  while (std::getline(fg, line)) if (!line.empty())
    golden.push_back(parse_row(line, 576));
  printf("[embed] %zu test ids loaded\n", ids.size());

  int errs = 0;
  for (size_t t = 0; t < ids.size(); t++) {
    top->token_id = ids[t];
    tick(top, tfp);  // posedge samples the id; vec registers the row
    // vec is 4608 bits = 144 words; word w holds bytes 4w..4w+3.
    int bad = 0;
    for (int k = 0; k < 576; k++) {
      uint8_t got = (top->vec[k / 4] >> (8 * (k % 4))) & 0xFF;
      if (got != golden[t][k]) bad++;
    }
    printf("tok 0x%04x (%5d) -> vec[0..7] = %02x %02x %02x %02x %02x %02x %02x %02x  %s\n",
           ids[t], ids[t],
           (top->vec[0] >>  0) & 0xFF, (top->vec[0] >>  8) & 0xFF,
           (top->vec[0] >> 16) & 0xFF, (top->vec[0] >> 24) & 0xFF,
           (top->vec[1] >>  0) & 0xFF, (top->vec[1] >>  8) & 0xFF,
           (top->vec[1] >> 16) & 0xFF, (top->vec[1] >> 24) & 0xFF,
           bad == 0 ? "OK" : "MISMATCH");
    if (bad) { printf("  .. %d of 576 bytes differ\n", bad); errs++; }
  }

  // Out-of-range id (>= 32000) must read zero by contract.
  top->token_id = 32000;
  tick(top, tfp);
  bool allzero = true;
  for (int w = 0; w < 144; w++) if (top->vec[w] != 0) allzero = false;
  printf("tok 0x7d00 (32000, out of range) -> %s\n",
         allzero ? "all-zero OK" : "NONZERO MISMATCH");
  if (!allzero) errs++;

  if (errs == 0) printf("EMBED_VLT PASS (%zu ids)\n", ids.size());
  else printf("EMBED_VLT FAIL (%d errs)\n", errs);
  tfp->close();
  return errs == 0 ? 0 : 1;
}
