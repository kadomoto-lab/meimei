// control flow: recursion, switch (jump table), function pointers, setjmp / longjmp, deep calls
#include "test.h"
#include <setjmp.h>

static long fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
static int ack(int m, int n) { return m == 0 ? n + 1 : (n == 0 ? ack(m - 1, 1) : ack(m - 1, ack(m, n - 1))); }

static __attribute__((noinline)) int sw(int x) {
    switch (x & 15) {
    case 0: return x * 3;      case 1: return x ^ 0x55;   case 2: return x - 7;     case 3: return x << 2;
    case 4: return ~x;         case 5: return x / 3;      case 6: return x % 11;    case 7: return x + 1000;
    case 8: return x & 0xf0;   case 9: return -x;         case 10: return x * x;    case 11: return x >> 1;
    case 12: return x | 1;     case 13: return 42;        case 14: return x * 7 + 1;
    default: return 0;
    }
}
static int add(int a, int b) { return a + b; }
static int sub(int a, int b) { return a - b; }
static int mul(int a, int b) { return a * b; }
static int (*const ops[3])(int, int) = {add, sub, mul};

static jmp_buf jb;
static __attribute__((noinline)) void thrower(int depth) {
    if (depth == 0) longjmp(jb, 77);
    thrower(depth - 1);
}

int main(void) {
    uint64_t h = 0;
    CHECK(fib(20) == 6765);
    CHECK(ack(2, 3) == 9);
    for (int i = -300; i < 300; i++) h = mix(h, (uint64_t)sw(i));
    int acc = 1;
    for (int i = 0; i < 100; i++) acc = ops[i % 3](acc, i + 1);
    h = mix(h, (uint64_t)acc);
    int r = setjmp(jb);
    if (r == 0) { thrower(20); CHECK(0); }
    CHECK(r == 77);
    // data-dependent branches
    int cnt = 0;
    for (unsigned x = 1; x < 400; x++) { unsigned y = x; while (y != 1) { y = (y & 1) ? 3 * y + 1 : y / 2; cnt++; } }
    h = mix(h, (uint64_t)cnt);
    printf("control checksum %016lx (collatz steps %d)\n", (unsigned long)h, cnt);
    return test_end("control");
}
