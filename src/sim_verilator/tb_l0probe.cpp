// tb_l0probe.cpp — feed one embed row, dump the layer-0 x_out frame.
// Usage: Vtb_l0probe <token-id> <embed_pt.hex> <out.hex>
// Dumps 576 lines of 2-digit hex (signed bytes) for golden_l0bit.py.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vtb_l0probe.h"
#include "verilated.h"

static Vtb_l0probe *top;

static void tick() {
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 4) {
    printf("usage: %s <id> <embed_pt.hex> <out.hex>\n", argv[0]);
    return 2;
  }
  int id = atoi(argv[1]);

  FILE *f = fopen(argv[2], "r");
  if (!f) {
    printf("L0PROBE FAIL cannot open %s\n", argv[2]);
    return 1;
  }
  static char line[16];
  // embed table is row-major byte-per-line; seek to row id.
  for (int r = 0; r < id * 576; r++)
    if (!fgets(line, sizeof line, f)) {
      printf("L0PROBE FAIL short table\n");
      return 1;
    }
  top = new Vtb_l0probe;
  top->clk = 0;
  top->rst_n = 0;
  top->x_valid = 0;
  // Flat 4608-bit frame = 144 LE words (tb_chunk_equiv idiom).
  for (int w = 0; w < 144; w++) top->x_row[w] = 0;
  for (int i = 0; i < 576; i++) {
    if (!fgets(line, sizeof line, f)) {
      printf("L0PROBE FAIL short row\n");
      return 1;
    }
    uint32_t by = strtoul(line, NULL, 16) & 0xFF;
    top->x_row[i / 4] |= by << (8 * (i % 4));
  }
  fclose(f);
  for (int i = 0; i < 5; i++) tick();
  top->rst_n = 1;
  tick();
  tick();
  top->x_valid = 1;
  tick();
  top->x_valid = 0;

  bool done = false;
  vluint64_t cyc = 0;
  while (!done && cyc < 20000000) {
    tick();
    cyc++;
    if (top->y_valid) done = true;
  }
  if (!done) {
    printf("L0PROBE FAIL timeout id=%d cyc=%llu\n", id,
           (unsigned long long)cyc);
    return 1;
  }
  FILE *o = fopen(argv[3], "w");
  for (int i = 0; i < 576; i++) {
    uint32_t by = (top->x_out[i / 4] >> (8 * (i % 4))) & 0xFF;
    fprintf(o, "%02x\n", by);
  }
  fclose(o);
  printf("L0PROBE id=%d cycles=%llu\n", id, (unsigned long long)cyc);
  return 0;
}
