/* Position-independent AArch64 code: write a line and exit 42. */
    .text
    .globl _start
_start:
    mov x0, #1
    adr x1, msg
    mov x2, #(end - msg)
    mov x8, #64
    svc #0
    mov x0, #42
    mov x8, #93
    svc #0
msg: .ascii "RUNTIME-CODE-RAN: bytes written at run time are executing\n"
end:
