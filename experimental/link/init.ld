/* The first program, at the start of the user half of the address space.
   Segments are page aligned: the kernel maps each with its own permissions
   and refuses two segments in one page. */
ENTRY(_start)
PHDRS {
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}
SECTIONS {
    . = 0x80000000;
    .text : { KEEP(*(.text.start)) *(.text .text.*) } :text
    . = ALIGN(4096);
    .rodata : { *(.rodata .rodata.*) *(.got .got.*) } :rodata
    . = ALIGN(4096);
    .data : { *(.data .data.*) } :data
    .bss (NOLOAD) : { *(.bss .bss.*) *(COMMON) } :data
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame*) }
}
