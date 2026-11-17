// Embench board support for the meimei SoC: the trigger reads the cycle / instret CSRs
// and stop_trigger prints one line the host-side runner parses ("EMBENCH cycles=.. instret=..")
#include <stdio.h>
#include <support.h>
#include "soc.h"

static uint64_t c0, i0;

void initialise_board(void) {}

void __attribute__((noinline)) start_trigger(void)
{
    i0 = rdinstret();
    c0 = rdcycle();
}

void __attribute__((noinline)) stop_trigger(void)
{
    uint64_t c1 = rdcycle();
    uint64_t i1 = rdinstret();
    printf("EMBENCH cycles=%lu instret=%lu\n", (unsigned long)(c1 - c0), (unsigned long)(i1 - i0));
}
