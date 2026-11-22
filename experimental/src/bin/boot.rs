//! The bootloader. The CPU starts here, at address 0 in flash, at EL1 with
//! the MMU off. It checks the image that follows it in flash, places the
//! kernel's segments and the init executable in RAM and jumps to the
//! kernel. Anything unexpected is said on the console and the machine is
//! powered off: it starts the image it was built with or nothing.
//!
//! It runs in place from read-only memory, so it has no writable data,
//! only a stack below the kernel's load address.
#![no_std]
#![no_main]

use core::arch::{asm, global_asm};
use core::panic::PanicInfo;
use core::slice;
use kcos_bare::elf::{Elf, PF_X};
use kcos_bare::layout::*;
use kcos_bare::{align_up, crc, fdt, power_off, uart};

global_asm!(
    r#"
    .section .text.start, "ax"
    .global _start
_start:
    msr daifset, #0xf
    ldr x0, =0x40200000
    mov sp, x0
    bl boot_main
    "#
);

fn die(why: &str) -> ! {
    uart::puts("boot: ");
    uart::puts(why);
    uart::puts("\n");
    power_off()
}

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    uart::puts("boot: panic");
    if let Some(at) = info.location() {
        uart::puts(" at ");
        uart::puts(at.file());
        uart::puts(":");
        uart::dec(at.line() as u64);
    }
    uart::puts("\n");
    power_off()
}

fn le32(d: &[u8], off: usize) -> usize {
    u32::from_le_bytes([d[off], d[off + 1], d[off + 2], d[off + 3]]) as usize
}

#[no_mangle]
extern "C" fn boot_main() -> ! {
    uart::init();
    uart::puts("kcos-boot ");
    uart::puts(env!("CARGO_PKG_VERSION"));
    uart::puts("\n");

    let el: u64;
    unsafe { asm!("mrs {}, CurrentEL", out(reg) el) };
    if el >> 2 != 1 {
        die("not started at EL1");
    }

    // The device tree says how much RAM there is to load into.
    let head = unsafe { slice::from_raw_parts(RAM_BASE as *const u8, 8) };
    let dtb = match fdt::total_size(head) {
        Some(n) if n <= 0x10_0000 => unsafe { slice::from_raw_parts(RAM_BASE as *const u8, n) },
        _ => die("no device tree at the start of RAM"),
    };
    let ram_end = match fdt::memory(dtb) {
        Some((RAM_BASE, size)) => RAM_BASE.saturating_add(size),
        _ => die("the device tree does not describe RAM at 0x40000000"),
    };

    // Header: magic, then little-endian u32 kernel length, init length and
    // checksum of both, then padding to 32 bytes. The two files follow.
    let header = unsafe { slice::from_raw_parts(IMG_OFF as *const u8, IMG_HEADER) };
    if &header[..8] != IMG_MAGIC {
        die("no image in flash");
    }
    let (kernel_len, init_len) = (le32(header, 8), le32(header, 12));
    if kernel_len + init_len > FLASH_SIZE - IMG_OFF - IMG_HEADER {
        die("the image is larger than the flash");
    }
    let payload = unsafe {
        slice::from_raw_parts((IMG_OFF + IMG_HEADER) as *const u8, kernel_len + init_len)
    };
    if crc::cksum(payload) as usize != le32(header, 16) {
        die("image checksum mismatch");
    }
    let (kernel, init) = payload.split_at(kernel_len);

    let Some(elf) = Elf::parse(kernel) else {
        die("the kernel is not an ARM64 executable");
    };
    let mut end = 0;
    let mut entry_ok = false;
    for i in 0..elf.phnum {
        let seg = match elf.segment(i) {
            Ok(Some(seg)) => seg,
            Ok(None) => continue,
            Err(()) => die("the kernel has a malformed segment"),
        };
        let top = match seg.top() {
            Some(top) if seg.vaddr >= KERNEL_BASE && top <= ram_end => top,
            _ => die("a kernel segment lies outside RAM"),
        };
        unsafe {
            let dst = seg.vaddr as *mut u8;
            dst.copy_from_nonoverlapping(seg.bytes.as_ptr(), seg.bytes.len());
            dst.add(seg.bytes.len()).write_bytes(0, seg.memsz as usize - seg.bytes.len());
        }
        entry_ok |= seg.flags & PF_X != 0 && (seg.vaddr..top).contains(&elf.entry);
        end = end.max(top);
    }
    if !entry_ok {
        die("the kernel's entry point is not in an executable segment");
    }

    // init goes on the first page after the kernel, as a file: the kernel
    // loads it.
    let init_at = align_up(end, PAGE);
    if init_at.saturating_add(init.len() as u64) > ram_end {
        die("init does not fit in RAM");
    }
    unsafe { (init_at as *mut u8).copy_from_nonoverlapping(init.as_ptr(), init.len()) };

    uart::puts("boot: image ok, kernel at ");
    uart::hex(elf.entry);
    uart::puts("\n");
    unsafe {
        asm!(
            "br {entry}",
            entry = in(reg) elf.entry,
            in("x0") RAM_BASE,
            in("x1") init_at,
            in("x2") init.len(),
            options(noreturn),
        )
    }
}
