// 32/64-bit integer arithmetic, M extension (mul/mulh/div/rem), shifts, comparisons
#include "test.h"

static uint64_t lcg(uint64_t *s) { *s = *s * 6364136223846793005ULL + 1442695040888963407ULL; return *s; }

int main(void) {
    uint64_t s = 1, h = 0;
    for (int i = 0; i < 400; i++) {
        uint64_t a = lcg(&s), b = lcg(&s) >> (i % 64);
        int64_t sa = (int64_t)a, sb = (int64_t)b;
        int32_t a32 = (int32_t)a, b32 = (int32_t)b;
        h = mix(h, a + b); h = mix(h, a - b); h = mix(h, a * b);
        h = mix(h, (uint64_t)(((unsigned __int128)a * b) >> 64));
        h = mix(h, (uint64_t)(((__int128)sa * sb) >> 64));
        h = mix(h, (uint64_t)(((__int128)sa * (unsigned __int128)b) >> 64));
        if (b) { h = mix(h, a / b); h = mix(h, a % b); }
        if (sb && !(sa == INT64_MIN && sb == -1)) { h = mix(h, sa / sb); h = mix(h, sa % sb); }
        if (b32 && !(a32 == INT32_MIN && b32 == -1)) { h = mix(h, a32 / b32); h = mix(h, a32 % b32); }
        if ((uint32_t)b) { h = mix(h, (uint32_t)a / (uint32_t)b); h = mix(h, (uint32_t)a % (uint32_t)b); }
        h = mix(h, (uint64_t)(a32 * b32)); h = mix(h, a << (b & 63)); h = mix(h, a >> (b & 63));
        h = mix(h, sa >> (b & 63)); h = mix(h, (uint32_t)a32 >> (b & 31)); h = mix(h, a32 >> (b & 31));
        h = mix(h, (sa < sb) + 2 * (a < b) + 4 * (a32 < b32) + 8 * (a == b));
        h = mix(h, __builtin_popcountll(a) + __builtin_clzll(a | 1) + __builtin_ctzll(b | (1ULL << 63)));
    }
    printf("int_ops checksum %016lx\n", (unsigned long)h);
    // a few identities
    for (int64_t a = -50; a <= 50; a += 7)
        for (int64_t b = -9; b <= 9; b += 2)
            CHECK((a / b) * b + a % b == a);
    CHECK((-7) / 2 == -3 && (-7) % 2 == -1 && 7u / 2u == 3u);
    CHECK((int64_t)((__int128)INT64_MAX * INT64_MAX >> 64) == 0x3fffffffffffffffLL);
    return test_end("int_ops");
}
