// meimei SoC: memory map and device access for bare-metal programs (keep in sync with rtl/mm_soc.sv)
#ifndef MEIMEI_SOC_H
#define MEIMEI_SOC_H
#include <stdint.h>

#define IMEM_BASE   0x80000000UL    // 64 KiB instruction SRAM (reset vector)
#define DMEM_BASE   0x80010000UL    // 64 KiB data SRAM
#define UART_BASE   0x10000000UL
#define GPIO_BASE   0x10001000UL
#define TIMER_BASE  0x10002000UL

#define REG32(a)    (*(volatile uint32_t *)(a))
#define REG64(a)    (*(volatile uint64_t *)(a))

#define UART_TXDATA REG32(UART_BASE + 0x00)   // W: byte to send
#define UART_STATUS REG32(UART_BASE + 0x04)   // R: bit0 TX ready, bit1 RX available
#define UART_RXDATA REG32(UART_BASE + 0x08)   // R: {bit8 valid, [7:0] data}; W bit0=1: pop
#define GPIO_IN     REG32(GPIO_BASE + 0x00)
#define GPIO_OUT    REG64(GPIO_BASE + 0x08)
#define TIMER_MTIME REG64(TIMER_BASE + 0x00)  // cycles since reset
#define TIMER_INSTRET REG64(TIMER_BASE + 0x08)
#define SIM_EXIT    REG32(TIMER_BASE + 0x10)  // W: end of run, value = exit code

static inline void uart_putc(char c) {
    while (!(UART_STATUS & 1)) ;
    UART_TXDATA = (uint8_t)c;
}
static inline int uart_getc(void) {           // -1 if no data
    uint32_t v = UART_RXDATA;
    if (!(v & 0x100)) return -1;
    UART_RXDATA = 1;
    return v & 0xff;
}
static inline uint64_t rdcycle(void)   { uint64_t v; __asm__ volatile ("rdcycle %0" : "=r"(v)); return v; }
static inline uint64_t rdinstret(void) { uint64_t v; __asm__ volatile ("rdinstret %0" : "=r"(v)); return v; }
static inline uint64_t rdtime(void)    { uint64_t v; __asm__ volatile ("rdtime %0" : "=r"(v)); return v; }
__attribute__((noreturn)) static inline void sim_exit(int code) {
    SIM_EXIT = (uint32_t)code;
    for (;;) ;
}
#endif
