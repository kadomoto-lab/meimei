// Zicsr (fflags / frm / fcsr / counters) and the SoC devices (GPIO, timer). The output does not
// depend on timing, so it can be compared with the host run, where this test only prints PASS.
#include "test.h"
#include "soc.h"
#ifndef HOST
#include <fenv.h>
static unsigned rd_fflags(void) { unsigned v; __asm__ volatile ("frflags %0" : "=r"(v)); return v; }
static void clr_fflags(void) { __asm__ volatile ("fsflags zero"); }
static double div_rm(double a, double b, int rm) {      // division with frm = rm (dynamic rounding)
    double r; unsigned old;
    __asm__ volatile ("fsrm %0, %1" : "=r"(old) : "r"(rm));
    __asm__ volatile ("fdiv.d %0, %1, %2" : "=f"(r) : "f"(a), "f"(b));
    __asm__ volatile ("fsrm %0" : : "r"(old));
    return r;
}
#endif

int main(void) {
#ifndef HOST
    volatile double one = 1.0, three = 3.0, zero = 0.0, m1 = -1.0, big = 1e308, tiny = 1e-308, ten = 10.0, e10 = 1e10;
    volatile double r;
    clr_fflags(); r = one + one;       CHECK(rd_fflags() == 0);
    clr_fflags(); r = one / three;     CHECK(rd_fflags() == FE_INEXACT);
    clr_fflags(); r = one / zero;      CHECK(rd_fflags() == FE_DIVBYZERO);
    clr_fflags(); r = __builtin_sqrt(m1); CHECK(rd_fflags() == FE_INVALID);
    clr_fflags(); r = big * ten;    CHECK(rd_fflags() == (FE_OVERFLOW | FE_INEXACT));
    clr_fflags(); r = tiny / e10;   CHECK(rd_fflags() == (FE_UNDERFLOW | FE_INEXACT));
    (void)r;
    double d0 = div_rm(1.0, 3.0, 0), d1 = div_rm(1.0, 3.0, 1), d2 = div_rm(-1.0, 3.0, 2), d3 = div_rm(1.0, 3.0, 3);
    CHECK(f64bits(d0) == 0x3fd5555555555555ULL && f64bits(d1) == 0x3fd5555555555555ULL);
    CHECK(f64bits(d2) == 0xbfd5555555555556ULL && f64bits(d3) == 0x3fd5555555555556ULL);
    CHECK(fesetround(FE_UPWARD) == 0 && fegetround() == FE_UPWARD);
    CHECK(f64bits(one / three) == 0x3fd5555555555556ULL);
    fesetround(FE_TONEAREST);
    // counters
    uint64_t c0 = rdcycle(), i0 = rdinstret();
    for (volatile int i = 0; i < 100; i++) ;
    uint64_t c1 = rdcycle(), i1 = rdinstret();
    CHECK(c1 > c0 && i1 >= i0 + 300);
    uint64_t t0 = TIMER_MTIME, t1 = TIMER_MTIME;
    CHECK(t1 > t0 && TIMER_INSTRET > i1);
    // GPIO output register read-back (MMIO store, then MMIO load)
    GPIO_OUT = 0x1234567890abcdefULL;
    CHECK(GPIO_OUT == 0x1234567890abcdefULL);
    *(volatile uint8_t *)(GPIO_BASE + 0x8) = 0x55;
    CHECK(GPIO_OUT == 0x1234567890abcd55ULL && GPIO_IN == 0);
    CHECK((UART_STATUS & 1) == 1 && uart_getc() == -1);
#endif
    return test_end("platform");
}
