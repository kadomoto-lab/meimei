// V80 self-test: exercises the image loaded through the host AXI port (IMEM code, .rodata/.data in
// DMEM), MMIO (UART TX polling), 64-bit multiply, byte/half/word stores and load-after-store, and
// the EXIT store. Prints what it computed; exit code 0 = pass. No newlib (freestanding build).
#include "soc.h"

// Loop length / expected accumulator. The cycle budget of a Verilator run is what sets the default:
// the model simulates at roughly the speed documented in CLAUDE.md (MM_SMALL ~6k, 8-wide ~1k
// cycles/s), so 100000 iterations (acc = 0xb0854925df02f88f) is only used on the real board.
//   make ITERS=100000 EXPECT=0xb0854925df02f88full
#ifndef LCG_ITERS
#define LCG_ITERS 1000
#endif
#ifndef EXPECT_ACC
#define EXPECT_ACC 0x79d0be5ae1616157ull
#endif

static const char banner[] = "v80 self-test: axi load / run / uart\n";   // .rodata (DMEM)
static const uint64_t seed = 0x0123456789abcdefull;                     // .data  (DMEM)
static volatile uint64_t acc;                                            // .bss   (DMEM)

static void puts_(const char *s) { while (*s) uart_putc(*s++); }

static void puthex(uint64_t v) {
    for (int i = 15; i >= 0; i--) {
        unsigned d = (unsigned)((v >> (4 * i)) & 0xf);
        uart_putc(d < 10 ? '0' + d : 'a' + d - 10);
    }
}

int kmain(void) {
    puts_(banner);

    uint64_t s = seed;
    for (int i = 0; i < LCG_ITERS; i++)
        s = s * 6364136223846793005ull + 1442695040888963407ull;
    acc = s;
    puts_("acc=");
    puthex(acc);
    uart_putc('\n');

    // 32-bit scratch: byte and halfword stores into a dword, then a load after the store
    volatile uint32_t scratch = 0xdeadbeefu;
    *((volatile uint8_t *)&scratch + 1) = 0x77;
    *((volatile uint16_t *)&scratch + 1) = 0x1234;
    puts_("scratch=");
    puthex(scratch);
    uart_putc('\n');

    int ok = (acc == EXPECT_ACC) && (scratch == 0x123477efu);
    puts_(ok ? "PASS\n" : "FAIL\n");
    sim_exit(ok ? 0 : 1);
}
