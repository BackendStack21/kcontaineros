/* The bootloader executes in place from the start of flash (address 0),
   which is read-only: it may have code and constants, nothing writable. */
ENTRY(_start)
SECTIONS {
    . = 0;
    .text : { KEEP(*(.text.start)) *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) *(.got .got.*) }
    .data : { *(.data .data.*) }
    .bss : { *(.bss .bss.*) *(COMMON) }
    ASSERT(SIZEOF(.data) == 0, "the bootloader runs from flash: no .data")
    ASSERT(SIZEOF(.bss) == 0, "the bootloader runs from flash: no .bss")
    ASSERT(. <= 0x10000, "the bootloader is larger than 64 KiB")
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame*) }
}
