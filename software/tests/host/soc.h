// host (x86-64 Linux) stand-in for software_tools/soc.h, used to produce the golden output
#ifndef MEIMEI_SOC_H
#define MEIMEI_SOC_H
#include <stdint.h>
#include <stdlib.h>
static inline uint64_t rdcycle(void) { return 0; }
static inline uint64_t rdinstret(void) { return 0; }
static inline void sim_exit(int code) { exit(code); }
#endif
