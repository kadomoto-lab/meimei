// F / D: arithmetic, fma, sqrt, min/max, conversions, comparisons, special values
#include "test.h"
#include <math.h>

static uint64_t lcg(uint64_t *s) { *s = *s * 6364136223846793005ULL + 1442695040888963407ULL; return *s; }
static double rnd_d(uint64_t *s) {               // moderate random double with random sign / exponent
    uint64_t v = lcg(s);
    uint64_t e = 1023 + (int)((v >> 52) % 41) - 20;
    uint64_t u = (v & 0x800fffffffffffffULL) | (e << 52);
    double d;
    memcpy(&d, &u, 8);
    return d;
}

int main(void) {
    uint64_t s = 7, h = 0;
    volatile double vz = 0.0;
    for (int i = 0; i < 300; i++) {
        double a = rnd_d(&s), b = rnd_d(&s), c = rnd_d(&s);
        float fa = (float)a, fb = (float)b, fc = (float)c;
        h = mix(h, f64bits(a + b)); h = mix(h, f64bits(a - b)); h = mix(h, f64bits(a * b));
        h = mix(h, f64bits(a / b)); h = mix(h, f64bits(sqrt(fabs(a)))); h = mix(h, f64bits(fma(a, b, c)));
        h = mix(h, f64bits(fmin(a, b))); h = mix(h, f64bits(fmax(a, b))); h = mix(h, f64bits(copysign(a, b)));
        h = mix(h, f32bits(fa + fb)); h = mix(h, f32bits(fa * fb)); h = mix(h, f32bits(fa / fb));
        h = mix(h, f32bits(sqrtf(fabsf(fa)))); h = mix(h, f32bits(fmaf(fa, fb, fc)));
        h = mix(h, f32bits((float)(a * 1e3))); h = mix(h, f64bits((double)fa));
        h = mix(h, (uint64_t)(int64_t)(a * 1e6)); h = mix(h, (uint64_t)(int32_t)(fb * 1e3f));
        h = mix(h, f64bits((double)(int64_t)lcg(&s))); h = mix(h, f32bits((float)(uint32_t)lcg(&s)));
        h = mix(h, (a < b) + 2 * (a <= b) + 4 * (a == b) + 8 * (fa > fb));
    }
    printf("float_ops checksum %016lx\n", (unsigned long)h);
    CHECK(0.1 + 0.2 != 0.3 && fabs(0.1 + 0.2 - 0.3) < 1e-15);
    CHECK(sqrt(2.0) * sqrt(2.0) != 2.0 && f64bits(sqrt(2.0)) == 0x3ff6a09e667f3bcdULL);
    CHECK(isinf(1.0 / vz) && isnan(vz / vz) && !(vz / vz == vz / vz));
    CHECK(f64bits(-0.0 * 1.0) == 0x8000000000000000ULL);
    CHECK((int)(2.5f) == 2 && (long)(-2.5) == -2 && lround(2.5) == 3);
    CHECK(f32bits(1.0f / 3.0f) == 0x3eaaaaab);
    CHECK(f64bits(fma(0x1p-60, 0x1p-60, 1.0)) == 0x3ff0000000000000ULL);
    CHECK(fma(1.0 + 0x1p-52, 1.0 - 0x1p-52, -1.0) == -0x1p-104);   // needs the fused (exact) product
    return test_end("float_ops");
}
