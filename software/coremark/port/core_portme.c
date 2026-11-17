/*
 * CoreMark port for the meimei SoC. Based on the EEMBC barebones template
 * (Copyright 2018 EEMBC, Apache-2.0, Original Author: Shay Gal-on).
 * Time base: the cycle counter (rdcycle); the result line reports CoreMark/MHz.
 */
#include "coremark.h"
#include "core_portme.h"
#include "soc.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

static CORETIMETYPE start_time_val, stop_time_val, start_instret, stop_instret;

void start_time(void) { start_instret = rdinstret(); start_time_val = rdcycle(); }
void stop_time(void)  { stop_time_val = rdcycle(); stop_instret = rdinstret(); }
CORE_TICKS get_time(void) { return stop_time_val - start_time_val; }
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)(ticks / CLOCKS_PER_SEC); }

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[]) {
    (void)argc; (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *)) ee_printf("ERROR! ee_ptr_int must hold a pointer!\n");
    if (sizeof(ee_u32) != 4) ee_printf("ERROR! ee_u32 must be 32 bits!\n");
    p->portable_id = 1;
}

void portable_fini(core_portable *p) {
    uint64_t cyc = stop_time_val - start_time_val, ins = stop_instret - start_instret;
    uint64_t cm = (uint64_t)ITERATIONS * 1000000ULL * 1000ULL / (cyc ? cyc : 1);   /* x1000 */
    uint64_t ipc = ins * 1000ULL / (cyc ? cyc : 1);
    ee_printf("Timed cycles     : %lu (instret %lu, IPC %lu.%03lu)\n",
              (unsigned long)cyc, (unsigned long)ins, (unsigned long)(ipc / 1000), (unsigned long)(ipc % 1000));
    ee_printf("CoreMark/MHz     : %lu.%03lu\n", (unsigned long)(cm / 1000), (unsigned long)(cm % 1000));
    p->portable_id = 0;
}
