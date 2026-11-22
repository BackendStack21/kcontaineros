//! The kernel. Entered by the bootloader at EL1 with the MMU off, x0 = the
//! device tree, x1 and x2 = where the init executable is and how long.
//!
//! It turns the MMU on with itself mapped write-xor-execute and out of
//! reach of EL0, loads init into the user half of the address space and
//! runs it at EL0. From then on it only runs when init traps: a system
//! call is served, anything else ends init. There is one process, one CPU
//! and no interrupt handler; when init ends, the machine powers off.
//!
//! Nothing allocates. Memory is handed out a page at a time and never
//! taken back.
#![no_std]
#![no_main]

mod mm;
mod trap;

use core::arch::{asm, global_asm};
use core::panic::PanicInfo;
use core::slice;
use kcos_bare::elf::{Elf, PF_W, PF_X};
use kcos_bare::layout::*;
use kcos_bare::{align_up, fdt, power_off, uart};
use mm::Mm;

global_asm!(
    r#"
    .section .text.start, "ax"
    .global _start
_start:
    msr daifset, #0xf
    adrp x9, __stack_top
    add x9, x9, :lo12:__stack_top
    mov sp, x9
    bl kmain

    // enter_user(entry, stack): leave for EL0 with every register cleared
    // and interrupts masked. The kernel's stack starts over: nothing
    // returns here.
    .section .text
    .global enter_user
enter_user:
    msr elr_el1, x0
    msr sp_el0, x1
    mov x0, #0x3c0
    msr spsr_el1, x0
    adrp x9, __stack_top
    add x9, x9, :lo12:__stack_top
    mov sp, x9
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30
    mov x\n, xzr
    .endr
    eret
    "#
);

extern "C" {
    fn enter_user(entry: u64, stack: u64) -> !;
    static __text_start: u8;
    static __text_end: u8;
    static __rodata_end: u8;
    static __kernel_end: u8;
}

static mut MM: Mm = Mm::empty();
static mut RAM_BYTES: u64 = 0;

/// How much RAM the kernel manages.
fn ram_bytes() -> u64 {
    unsafe { RAM_BYTES }
}

/// The memory manager. One CPU, and no exception is taken while the
/// kernel runs, so there is never a second reference.
fn mm() -> &'static mut Mm {
    unsafe { &mut *(&raw mut MM) }
}

fn fatal(why: &str) -> ! {
    uart::puts("kernel: ");
    uart::puts(why);
    uart::puts("\n");
    power_off()
}

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    uart::puts("kernel: panic");
    if let Some(at) = info.location() {
        uart::puts(" at ");
        uart::puts(at.file());
        uart::puts(":");
        uart::dec(at.line() as u64);
    }
    uart::puts("\n");
    power_off()
}

/// The interrupt controller passes the UART's line on to the CPU. The CPU
/// keeps interrupts masked: a pending one only wakes it from `wfi`.
fn gic_init() {
    let reg = |base: usize, off: usize| (base + off) as *mut u32;
    unsafe {
        // GICD_ISENABLERn, GICD_ITARGETSRn (CPU 0), GICD_CTLR.
        reg(GICD, 0x100 + 4 * (UART_INTID / 32)).write_volatile(1 << (UART_INTID % 32));
        ((GICD + 0x800 + UART_INTID) as *mut u8).write_volatile(1);
        reg(GICD, 0).write_volatile(1);
        // GICC_PMR: every priority; GICC_CTLR.
        reg(GICC, 4).write_volatile(0xff);
        reg(GICC, 0).write_volatile(1);
    }
}

/// Map the executable at EL0, each segment with its own permissions, and
/// a stack. Returns the entry point.
fn load_init(file: &[u8]) -> u64 {
    let Some(elf) = Elf::parse(file) else {
        fatal("init is not an ARM64 executable");
    };
    let stack_bottom = USER_END - USER_STACK;
    let mut entry_ok = false;
    for i in 0..elf.phnum {
        let seg = match elf.segment(i) {
            Ok(Some(seg)) => seg,
            Ok(None) => continue,
            Err(()) => fatal("init has a malformed segment"),
        };
        let attrs = match (seg.flags & PF_W != 0, seg.flags & PF_X != 0) {
            (true, true) => fatal("init has a segment that is writable and executable"),
            (true, false) => mm::USER_RW,
            (false, true) => mm::USER_RX,
            (false, false) => mm::USER_RO,
        };
        // A guard page stays free below the stack.
        let top = match seg.top() {
            Some(top) if seg.vaddr >= USER_BASE && top <= stack_bottom - PAGE => top,
            _ => fatal("an init segment lies outside the user address space"),
        };
        if seg.vaddr % PAGE != 0 {
            fatal("an init segment does not start on a page");
        }
        let mut off = 0;
        while off < seg.memsz {
            let from = seg.bytes.get(off as usize..).unwrap_or(&[]);
            let n = from.len().min(PAGE as usize);
            let page = mm().frame().and_then(|frame| {
                unsafe { (frame as *mut u8).copy_from_nonoverlapping(from.as_ptr(), n) };
                mm().map_page(seg.vaddr + off, frame, attrs)
            });
            if page.is_none() {
                fatal("init cannot be mapped: out of memory, or two segments share a page");
            }
            off += PAGE;
        }
        entry_ok |= seg.flags & PF_X != 0 && (seg.vaddr..top).contains(&elf.entry);
    }
    if !entry_ok {
        fatal("init's entry point is not in an executable segment");
    }
    let mut va = stack_bottom;
    while va < USER_END {
        if mm().frame().and_then(|frame| mm().map_page(va, frame, mm::USER_RW)).is_none() {
            fatal("out of memory for init's stack");
        }
        va += PAGE;
    }
    // What was just written as data is about to be executed.
    unsafe { asm!("ic iallu", "dsb nsh", "isb") };
    elf.entry
}

#[no_mangle]
extern "C" fn kmain(dtb: u64, init_at: u64, init_len: u64) -> ! {
    uart::puts("kcos-kernel ");
    uart::puts(env!("CARGO_PKG_VERSION"));
    uart::puts("\n");
    trap::install();

    let head = unsafe { slice::from_raw_parts(dtb as *const u8, 8) };
    let ram = fdt::total_size(head)
        .filter(|&n| n <= 0x10_0000)
        .and_then(|n| fdt::memory(unsafe { slice::from_raw_parts(dtb as *const u8, n) }));
    let Some((RAM_BASE, ram_size)) = ram else {
        fatal("the device tree does not describe RAM at 0x40000000");
    };
    // RAM above the user half's base is not used.
    let ram_end = RAM_BASE.saturating_add(ram_size).min(USER_BASE);
    let ram_size = ram_end - RAM_BASE;
    unsafe { RAM_BYTES = ram_size };

    // Free memory starts after the kernel and the init file.
    let kernel_end = &raw const __kernel_end as u64;
    let init_end = init_at.saturating_add(init_len);
    if init_at < kernel_end || init_end > ram_end {
        fatal("the init file is not where a bootloader would put it");
    }
    *mm() = Mm::new(align_up(init_end, PAGE), ram_end);

    let (text, text_end, rodata_end) = (
        &raw const __text_start as u64,
        &raw const __text_end as u64,
        &raw const __rodata_end as u64,
    );
    let mapped = (|| {
        let m = mm();
        m.map_kernel(GICD as u64, GICD as u64 + 0x20_0000, mm::DEVICE)?;
        m.map_kernel(UART as u64, UART as u64 + 0x20_0000, mm::DEVICE)?;
        m.map_kernel(RAM_BASE, text, mm::KERNEL_RW)?;
        m.map_kernel(text, text_end, mm::KERNEL_RX)?;
        m.map_kernel(text_end, rodata_end, mm::KERNEL_RO)?;
        m.map_kernel(rodata_end, ram_end, mm::KERNEL_RW)
    })();
    if mapped.is_none() {
        fatal("out of memory for the page tables");
    }
    mm().enable();

    gic_init();
    uart::signal_rx();

    let file = unsafe { slice::from_raw_parts(init_at as *const u8, init_len as usize) };
    let entry = load_init(file);

    uart::puts("kernel: ram ");
    uart::dec(ram_size >> 20);
    uart::puts(" MiB, mmu on, init at EL0\n");
    unsafe { enter_user(entry, USER_END) }
}
