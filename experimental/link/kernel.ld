/* The kernel runs at the address it is loaded at, 2 MiB into RAM. Text,
   constants and data are separate segments on separate pages, so each can
   be mapped with its own permissions. The stack is the end of .bss. */
ENTRY(_start)
PHDRS {
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}
SECTIONS {
    . = 0x40200000;
    __text_start = .;
    .text : { KEEP(*(.text.start)) *(.text .text.*) } :text
    . = ALIGN(4096);
    __text_end = .;
    .rodata : { *(.rodata .rodata.*) *(.got .got.*) } :rodata
    . = ALIGN(4096);
    __rodata_end = .;
    .data : { *(.data .data.*) } :data
    .bss (NOLOAD) : {
        *(.bss .bss.*) *(COMMON)
        . = ALIGN(16);
        . += 0x10000;
        __stack_top = .;
    } :data
    . = ALIGN(4096);
    __kernel_end = .;
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame*) }
}
