# Startup for the meimei SoC (bare metal, M mode only, no traps)
    .section .text.init, "ax"
    .globl _start
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top
    # clear .sbss / .bss
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:  csrw    fcsr, zero              # frm = RNE, no exception flags
    # static constructors
    la      s0, __init_array_start
    la      s1, __init_array_end
3:  bgeu    s0, s1, 4f
    ld      t0, 0(s0)
    jalr    t0
    addi    s0, s0, 8
    j       3b
4:  li      a0, 0
    li      a1, 0
    call    main
    call    exit                    # newlib: atexit handlers, flush stdio, then _exit
5:  j       5b
