//! What the bootloader, the kernel and the first program have in common.
//! `core` only: nothing here allocates.
#![no_std]

pub mod abi;
pub mod crc;
pub mod elf;
pub mod fdt;
pub mod put;
pub mod uart;

/// The machine: QEMU's `virt` board with a GICv2. Addresses are fixed by
/// the board, the amount of RAM is read from the device tree.
pub mod layout {
    /// Flash holds the image: the bootloader, then at `IMG_OFF` a header
    /// and the kernel and init executables.
    pub const FLASH_SIZE: usize = 0x0400_0000;
    pub const IMG_OFF: usize = 0x1_0000;
    pub const IMG_HEADER: usize = 32;
    pub const IMG_MAGIC: &[u8; 8] = b"KCOSIMG1";

    pub const GICD: usize = 0x0800_0000;
    pub const GICC: usize = 0x0801_0000;
    pub const UART: usize = 0x0900_0000;
    /// The UART is shared peripheral interrupt 1.
    pub const UART_INTID: usize = 33;

    /// QEMU puts the device tree at the start of RAM. The bootloader's
    /// stack lies below the kernel, which is loaded 2 MiB in.
    pub const RAM_BASE: u64 = 0x4000_0000;
    pub const KERNEL_BASE: u64 = 0x4020_0000;

    /// The kernel maps RAM at its physical address below `USER_BASE`; the
    /// program owns the gigabyte above it, with its stack at the top.
    pub const USER_BASE: u64 = 0x8000_0000;
    pub const USER_END: u64 = 0xC000_0000;
    pub const USER_STACK: u64 = 0x1_0000;

    pub const PAGE: u64 = 4096;
}

pub const fn align_up(v: u64, a: u64) -> u64 {
    (v + a - 1) & !(a - 1)
}

/// PSCI SYSTEM_OFF. QEMU answers it itself: on `hvc` from EL1, and on
/// `smc` when the machine has an EL2 and was started there.
pub fn power_off() -> ! {
    use core::arch::asm;
    let el: u64;
    unsafe {
        asm!("mrs {}, CurrentEL", out(reg) el);
        if el >> 2 == 1 {
            asm!("hvc #0", inout("x0") 0x8400_0008u64 => _,
                lateout("x1") _, lateout("x2") _, lateout("x3") _);
        } else {
            asm!("smc #0", inout("x0") 0x8400_0008u64 => _,
                lateout("x1") _, lateout("x2") _, lateout("x3") _);
        }
    }
    loop {
        unsafe { asm!("wfi") };
    }
}
