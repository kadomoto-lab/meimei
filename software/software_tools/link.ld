/* meimei SoC: Harvard memory map (code in IMEM, everything loaded or stored in DMEM) */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    IMEM (rx)  : ORIGIN = 0x80000000, LENGTH = 64K
    DMEM (rw)  : ORIGIN = 0x80010000, LENGTH = 64K
}
STACK_SIZE = 16K;

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text .text.*)
    } > IMEM

    /* data loads cannot read IMEM: read-only data lives in DMEM too */
    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > DMEM
    .init_array : {
        . = ALIGN(8);
        __init_array_start = .;
        KEEP(*(SORT(.init_array.*)))
        KEEP(*(.init_array))
        __init_array_end = .;
    } > DMEM
    .data : {
        *(.data .data.*)
    } > DMEM
    .sdata : {
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    } > DMEM
    .sbss (NOLOAD) : {
        . = ALIGN(8);
        __bss_start = .;
        *(.sbss .sbss.*) *(.scommon)
    } > DMEM
    .bss (NOLOAD) : {
        *(.bss .bss.*) *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > DMEM
    . = ALIGN(16);
    _end = .;                       /* heap (sbrk) starts here */
    __heap_end = ORIGIN(DMEM) + LENGTH(DMEM) - STACK_SIZE;
    __stack_top = ORIGIN(DMEM) + LENGTH(DMEM);
    ASSERT(_end <= __heap_end, "DMEM overflow: data + bss + stack exceed 64 KiB")

    /DISCARD/ : { *(.eh_frame .eh_frame_hdr .note.* .comment .riscv.attributes) }
}
