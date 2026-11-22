//! Exceptions. The only one expected is a synchronous exception from EL0:
//! a system call, or the program doing something it may not. Anything
//! taken while the kernel itself runs is a bug in the kernel: it is
//! reported and the machine powers off.

use crate::{fatal, mm};
use core::arch::{asm, global_asm};
use kcos_bare::abi::*;
use kcos_bare::{power_off, uart};

global_asm!(
    r#"
    .macro fatal_vector n
    .balign 128
    mov x0, #\n
    b fatal_entry
    .endm

    .section .text
    .balign 2048
vectors:
    // From EL1 on SP_EL0 (never used), then from EL1: all fatal.
    fatal_vector 0
    fatal_vector 1
    fatal_vector 2
    fatal_vector 3
    fatal_vector 4
    fatal_vector 5
    fatal_vector 6
    fatal_vector 7
    // From EL0: synchronous, then IRQ, FIQ, SError (all masked).
    .balign 128
    b el0_sync
    fatal_vector 9
    fatal_vector 10
    fatal_vector 11
    // From 32-bit EL0, which does not exist here.
    fatal_vector 12
    fatal_vector 13
    fatal_vector 14
    fatal_vector 15

fatal_entry:
    adrp x9, __stack_top
    add x9, x9, :lo12:__stack_top
    mov sp, x9
    bl trap_fatal

    // Save x0..x30, let trap_el0 change them, restore, return.
el0_sync:
    sub sp, sp, #256
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]
    mov x0, sp
    bl trap_el0
    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    add sp, sp, #256
    eret
    "#
);

extern "C" {
    static vectors: u8;
}

pub fn install() {
    unsafe { asm!("msr vbar_el1, {}", "isb", in(reg) &raw const vectors) };
}

fn sysreg() -> (u64, u64, u64) {
    let (esr, elr, far): (u64, u64, u64);
    unsafe {
        asm!("mrs {}, esr_el1", "mrs {}, elr_el1", "mrs {}, far_el1",
            out(reg) esr, out(reg) elr, out(reg) far)
    };
    (esr, elr, far)
}

#[no_mangle]
extern "C" fn trap_fatal(vector: u64) -> ! {
    let (esr, elr, far) = sysreg();
    uart::puts("kernel: fatal exception, vector ");
    uart::dec(vector);
    uart::puts(", esr ");
    uart::hex(esr);
    uart::puts(", pc ");
    uart::hex(elr);
    uart::puts(", address ");
    uart::hex(far);
    uart::puts("\n");
    power_off()
}

/// `regs` are the program's x0..x30.
#[no_mangle]
extern "C" fn trap_el0(regs: &mut [u64; 31]) {
    let (esr, elr, far) = sysreg();
    // The exception class. 0x15 is `svc` from 64-bit code.
    let class = esr >> 26;
    if class == 0x15 {
        regs[0] = syscall(regs[8], regs[0], regs[1]) as u64;
        return;
    }
    let (what, has_address) = match class {
        0x00 => ("undefined instruction", false),
        0x01 => ("wfi is not allowed", false),
        0x07 => ("floating point is not available", false),
        0x18 => ("privileged instruction", false),
        0x20 => ("instruction abort", true),
        0x22 => ("misaligned pc", true),
        0x24 => ("data abort", true),
        0x26 => ("misaligned stack pointer", false),
        0x3c => ("breakpoint", false),
        _ => ("unexpected exception", false),
    };
    uart::puts("kernel: init killed: ");
    uart::puts(what);
    uart::puts(" at pc ");
    uart::hex(elr);
    if has_address {
        uart::puts(", address ");
        uart::hex(far);
    } else if what == "unexpected exception" {
        uart::puts(", esr ");
        uart::hex(esr);
    }
    uart::puts("\n");
    fatal("power off")
}

fn syscall(nr: u64, a0: u64, a1: u64) -> i64 {
    let m = mm();
    match nr {
        SYS_EXIT => {
            uart::puts("kernel: init exited with status ");
            uart::dec(a0 & 0xff);
            uart::puts("\n");
            fatal("power off")
        }
        SYS_WRITE => {
            let ok = m.with_user(a0, a1, false, |p, n| {
                uart::put(unsafe { core::slice::from_raw_parts(p, n) })
            });
            if ok { a1 as i64 } else { EFAULT }
        }
        SYS_READ => {
            if !m.with_user(a0, a1, true, |_, _| ()) {
                return EFAULT;
            }
            // Take what is there; with nothing stored yet, sleep until
            // the UART raises its interrupt line.
            let mut got = 0;
            while got < a1 {
                match uart::getb() {
                    Some(b) => {
                        m.with_user(a0 + got, 1, true, |p, _| unsafe { p.write(b) });
                        got += 1;
                    }
                    None if got > 0 => break,
                    None => unsafe { asm!("wfi") },
                }
            }
            got as i64
        }
        SYS_INFO => {
            let info = [crate::ram_bytes(), m.free_bytes()];
            let mut at = 0;
            let ok = m.with_user(a0, 16, true, |p, n| unsafe {
                p.copy_from_nonoverlapping((info.as_ptr() as *const u8).add(at), n);
                at += n;
            });
            if ok { 0 } else { EFAULT }
        }
        _ => ENOSYS,
    }
}
