// libc: string / memory functions, sprintf, malloc / realloc / free, qsort / bsearch
#include "test.h"
#include <stdlib.h>

static int cmp_i64(const void *a, const void *b) {
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return (x > y) - (x < y);
}

int main(void) {
    char buf[256], buf2[256];
    uint64_t h = 0;
    memset(buf, 'a', sizeof buf);
    for (int i = 0; i < 200; i++) buf[i] = (char)('A' + i % 26);
    buf[200] = 0;
    CHECK(strlen(buf) == 200);
    memcpy(buf2, buf, 201);
    CHECK(strcmp(buf, buf2) == 0 && memcmp(buf, buf2, 201) == 0);
    memmove(buf2 + 3, buf2, 50);
    CHECK(buf2[3] == 'A' && buf2[52] == buf[49]);
    CHECK(strchr(buf, 'Z') == buf + 25 && strrchr(buf, 'A') == buf + 182);
    strcpy(buf2, "hello, ");
    strcat(buf2, "meimei");
    CHECK(strcmp(buf2, "hello, meimei") == 0 && strncmp(buf2, "help", 3) == 0);
    int n = sprintf(buf, "%d|%u|%x|%lx|%s|%c|%05d|%-4d|%ld", -42, 42u, 0xbeefu, 0x123456789abcdefUL, "str", 'q', 17, 3, -1234567890123L);
    printf("sprintf: %s (%d)\n", buf, n);
    CHECK(strcmp(buf, "-42|42|beef|123456789abcdef|str|q|00017|3   |-1234567890123") == 0);
    CHECK(atoi("-123") == -123 && strtol("0x7f", 0, 16) == 127 && strtoul("777", 0, 8) == 511);

    // heap
    int64_t *v = malloc(1000 * sizeof *v);
    CHECK(v != 0);
    uint64_t s = 3;
    for (int i = 0; i < 1000; i++) { s = s * 6364136223846793005ULL + 1; v[i] = (int64_t)(s >> 3) - (int64_t)(1ULL << 59); }
    qsort(v, 1000, sizeof *v, cmp_i64);
    for (int i = 1; i < 1000; i++) CHECK(v[i - 1] <= v[i]);
    for (int i = 0; i < 1000; i += 37) {
        int64_t *p = bsearch(&v[i], v, 1000, sizeof *v, cmp_i64);
        CHECK(p && *p == v[i]);
        h = mix(h, (uint64_t)v[i]);
    }
    v = realloc(v, 2000 * sizeof *v);
    CHECK(v != 0 && v[999] >= v[0]);
    char *blocks[32];
    for (int i = 0; i < 32; i++) { blocks[i] = malloc(16 + 24 * i); memset(blocks[i], i, 16 + 24 * i); }
    for (int i = 0; i < 32; i += 2) free(blocks[i]);
    for (int i = 1; i < 32; i += 2) { CHECK(blocks[i][24 * i] == (char)i); h = mix(h, (uint64_t)blocks[i][7]); }
    free(v);
    printf("string_mem checksum %016lx\n", (unsigned long)h);
    return test_end("string_mem");
}
