// Minimal start-up for the V80 self-test: no newlib, only what the self-test needs.
    .section .text.init, "ax"
    .globl _start
_start:
    .option push
    .option norelax
    la      sp, __stack_top
    .option pop
    call    kmain
1:  j       1b
