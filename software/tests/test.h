// tiny self-checking helpers shared by the C tests
#ifndef TEST_H
#define TEST_H
#include <stdio.h>
#include <stdint.h>
#include <string.h>
static int test_fail;
#define CHECK(cond) do { if (!(cond)) { printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); test_fail++; } } while (0)
static inline uint64_t mix(uint64_t h, uint64_t v) { h ^= v; h *= 0x100000001b3ULL; return h ^ (h >> 29); }
static inline uint64_t f64bits(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static inline uint32_t f32bits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline int test_end(const char *name) {
    printf("%s: %s\n", name, test_fail ? "FAIL" : "PASS");
    return test_fail ? 1 : 0;
}
#endif
