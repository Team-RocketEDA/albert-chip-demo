/* mcu_fw.c — RV32IM control-plane firmware (architectural C, freestanding).
 * Uses ONLY: LW/SW/ADD/SUB/SHIFT/LOGIC/BRANCH/JAL/JALR/LUI/AUIPC/MUL/MULH + CSR.
 * No DIV/REM (see fixed-point recip below), no floats. Q-formats per 08/09. */
#include <stdint.h>

/* ---- MMIO ---- */
#define MMIO32(a) (*(volatile uint32_t *)(a))
#define BASE      0x40000000u
#define CTRL      MMIO32(BASE + 0x00)
#define STATUS    MMIO32(BASE + 0x04)
#define LAYER_CFG MMIO32(BASE + 0x08)
#define T_RECAL   MMIO32(BASE + 0x0C)
#define CAL_BASE  MMIO32(BASE + 0x10)
#define REF_EXP   MMIO32(BASE + 0x14)
#define REF_MEAS  MMIO32(BASE + 0x18)
#define SCORE_C   MMIO32(BASE + 0x1C)
#define SCORE_T   MMIO32(BASE + 0x20)
#define MARGIN_TH MMIO32(BASE + 0x24)
#define MARGIN    MMIO32(BASE + 0x28)
#define IRQ_ARG   MMIO32(BASE + 0x2C)
#define FW_STATUS MMIO32(BASE + 0x30)

#define CAL_WIN 0x40010000u
#define CAL_SLOT(layer, block, phase, tile, col) \
    MMIO32(CAL_WIN + (uint32_t)(((layer) << 20) | ((block) << 18) | ((phase) << 16) | ((tile) << 10) | (col)))

/* Fixed-point Q16.16 multiply (MUL/MULH only). */
static inline int32_t qmul(int32_t a, int32_t b) {
    int64_t p = (int64_t)a * (int64_t)b;
    return (int32_t)(p >> 16);
}

/* Reciprocal 1/x in Q16.16 via 2 Newton-Raphson iters, seed from top bits.
 * No DIV instruction emitted. x > 0. */
static int32_t qrecip(uint32_t x) {
    int lz = __builtin_clz(x);              /* LZCNT-class idiom, ALU only */
    uint32_t xs = x << lz;                  /* normalize to [0.5, 1) */
    uint32_t y = (3u << 30) - xs;           /* seed: y0 = 3 - x (Q2.30) */
    y = (uint32_t)(((uint64_t)y * ((3u << 30) - (uint64_t)(((uint64_t)y * xs) >> 30))) >> 30);
    y = (uint32_t)(((uint64_t)y * ((3u << 30) - (uint64_t)(((uint64_t)y * xs) >> 30))) >> 30);
    return (int32_t)(y >> lz);              /* denormalize to Q16.16 */
}

/* ---- IRQ 0: recalibration. s_new = s_old * ref_exp/ref_meas ---- */
void recal_isr(void) {
    uint32_t arg = IRQ_ARG;                /* {layer[23:20],block[19:18], */
    uint32_t layer = (arg >> 20) & 0xFu;   /*  phase[17:16],tile[15:10]} */
    uint32_t block = (arg >> 18) & 0x3u;
    uint32_t phase = (arg >> 16) & 0x3u;
    uint32_t tile  = (arg >> 10) & 0x3Fu;
    uint32_t exp = REF_EXP, meas = REF_MEAS;
    if (meas == 0) { FW_STATUS = 0xE1; return; }   /* degenerate guard */
    /* ratio = exp/meas in Q16.16 = exp * recip(meas) */
    int32_t ratio = qmul((int32_t)(exp << 16), qrecip(meas << 16));
    for (uint32_t col = 0; col < 512u; col++) {
        int32_t s = (int32_t)CAL_SLOT(layer, block, phase, tile, col);
        s = qmul(s, ratio);                  /* per-col slope update */
        CAL_SLOT(layer, block, phase, tile, col) = (uint32_t)s;
    }
    FW_STATUS = 0x01;                        /* recal heartbeat */
}

/* ---- IRQ 1: layer boundary. l<11 loop, l==11 pooler steer + report ---- */
volatile uint32_t g_layer = 0, g_num_layers = 12, g_done = 0;

void layer_done_isr(void) {
    if (MARGIN > MARGIN_TH) {                /* early exit: stop, report */
        g_done = 1u;
        FW_STATUS = (SCORE_C << 16) | (SCORE_T & 0xFFFFu);
        return;
    }
    if (g_layer < g_num_layers - 1u) {
        g_layer++;
        CTRL = 0x1u;                         /* kick next layer */
    } else {
        CTRL = 0x2u;                         /* steer bank to pooler */
        g_done = 1u;
        FW_STATUS = (SCORE_C << 16) | (SCORE_T & 0xFFFFu);
    }
}

/* ---- IRQ 3: phase boundary — switch resident cal bank, no PCM traffic ---- */
void phase_isr(void) {
    CAL_BASE = IRQ_ARG & 0x00FF0000u;  /* point window at {layer,block,phase} */
}

/* ---- trap entry (mtvec direct): save, C dispatch, MRET ---- */
void recal_isr(void);
void layer_done_isr(void);
void error_isr(void);
void phase_isr(void);
void trap_entry(void) __attribute__((naked));
void trap_dispatch(uint32_t cause) {
    uint32_t irq = cause & 0x3u;   /* custom: mcause low bits = IRQ# */
    if (irq == 0u) recal_isr();
    else if (irq == 1u) layer_done_isr();
    else if (irq == 2u) error_isr();
    else phase_isr();
}
void trap_entry(void) {
    __asm__ volatile(
        "addi sp, sp, -16\n"
        "sw   ra, 12(sp)\n"
        "sw   t0, 8(sp)\n"
        "csrr a0, mcause\n"
        "jal  ra, trap_dispatch\n"
        "lw   ra, 12(sp)\n"
        "lw   t0, 8(sp)\n"
        "addi sp, sp, 16\n"
        "mret\n");
}

/* ---- IRQ 2: fatal FIFO error — freeze, latch, halt ---- */
void error_isr(void) {
    FW_STATUS = 0xDEAD0000u | (STATUS & 0xFFFFu);
    CTRL = 0x4u;                             /* error_halt */
    for (;;) { __asm__ volatile("wfi"); }
}

/* ---- boot: config, defaults, verify, start, sleep ---- */
void boot(uint32_t seq_len, uint32_t num_layers, uint32_t t_recal,
          uint32_t margin_th) {
    LAYER_CFG = (seq_len & 0xFFu) | ((num_layers & 0xFu) << 8);
    T_RECAL = t_recal;
    MARGIN_TH = margin_th;
    g_num_layers = num_layers;
    /* weights assumed programmed closed-loop externally; verify path: */
    if (REF_MEAS == 0u) { FW_STATUS = 0xE0; for (;;) { __asm__ volatile("wfi"); } }
    g_layer = 0;
    CTRL = 0x1u;                             /* start layer 0 */
    for (;;) { __asm__ volatile("wfi"); }    /* ISRs do the rest */
}
