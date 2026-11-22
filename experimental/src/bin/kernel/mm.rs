//! Memory: pages handed out in order from what the kernel does not occupy,
//! and one set of page tables (4 KiB pages, 39-bit addresses, TTBR0).
//!
//! The kernel sees RAM and its two devices at their physical addresses,
//! none of it accessible from EL0. The program's pages are also mapped
//! from `USER_BASE` up with EL0 access. Nothing is both writable and
//! executable, for either.

use core::arch::asm;
use kcos_bare::layout::*;

const VALID: u64 = 1;
/// At levels 1 and 2: a table rather than a block. At level 3: a page.
const TABLE: u64 = 2;
const ADDR: u64 = 0x0000_ffff_ffff_f000;
const BLOCK: u64 = 0x20_0000;

/// MAIR index 1: device memory.
const ATTR_DEVICE: u64 = 1 << 2;
const AP_EL0: u64 = 1 << 6;
const AP_RO: u64 = 1 << 7;
const SH_INNER: u64 = 3 << 8;
const AF: u64 = 1 << 10;
const PXN: u64 = 1 << 53;
const UXN: u64 = 1 << 54;

pub const KERNEL_RW: u64 = AF | SH_INNER | PXN | UXN;
pub const KERNEL_RO: u64 = KERNEL_RW | AP_RO;
pub const KERNEL_RX: u64 = AF | SH_INNER | AP_RO | UXN;
pub const DEVICE: u64 = AF | ATTR_DEVICE | PXN | UXN;
pub const USER_RW: u64 = AF | SH_INNER | AP_EL0 | PXN | UXN;
pub const USER_RO: u64 = USER_RW | AP_RO;
pub const USER_RX: u64 = AF | SH_INNER | AP_EL0 | AP_RO | PXN;

pub struct Mm {
    next: u64,
    end: u64,
    root: u64,
}

impl Mm {
    pub const fn empty() -> Mm {
        Mm { next: 0, end: 0, root: 0 }
    }

    /// Free memory is `start..end`, page aligned.
    pub fn new(start: u64, end: u64) -> Mm {
        Mm { next: start, end, root: 0 }
    }

    pub fn free_bytes(&self) -> u64 {
        self.end - self.next
    }

    /// A zeroed page.
    pub fn frame(&mut self) -> Option<u64> {
        if self.end - self.next < PAGE {
            return None;
        }
        let frame = self.next;
        self.next += PAGE;
        unsafe { (frame as *mut u8).write_bytes(0, PAGE as usize) };
        Some(frame)
    }

    /// The level 2 table for `va`, made if it is not there.
    fn level2(&mut self, va: u64) -> Option<*mut u64> {
        if self.root == 0 {
            self.root = self.frame()?;
        }
        self.descend(self.root as *mut u64, va >> 30)
    }

    /// The table that entry `index` of `table` points to, made if the
    /// entry is empty. None if the entry is a block.
    fn descend(&mut self, table: *mut u64, index: u64) -> Option<*mut u64> {
        let entry = unsafe { table.add((index & 511) as usize) };
        let e = unsafe { entry.read() };
        if e & VALID == 0 {
            let new = self.frame()?;
            unsafe { entry.write(new | TABLE | VALID) };
            Some(new as *mut u64)
        } else if e & TABLE != 0 {
            Some((e & ADDR) as *mut u64)
        } else {
            None
        }
    }

    /// One page. None if out of memory or if `va` is already mapped.
    pub fn map_page(&mut self, va: u64, pa: u64, attrs: u64) -> Option<()> {
        let l2 = self.level2(va)?;
        let l3 = self.descend(l2, va >> 21)?;
        let entry = unsafe { l3.add((va >> 12 & 511) as usize) };
        if unsafe { entry.read() } & VALID != 0 {
            return None;
        }
        unsafe { entry.write(pa | attrs | TABLE | VALID) };
        Some(())
    }

    /// `start..end` at its physical address, in 2 MiB blocks where it can
    /// be and in pages where it cannot.
    pub fn map_kernel(&mut self, start: u64, end: u64, attrs: u64) -> Option<()> {
        let mut at = start;
        while at < end {
            if at % BLOCK == 0 && end - at >= BLOCK {
                let l2 = self.level2(at)?;
                unsafe { l2.add((at >> 21 & 511) as usize).write(at | attrs | VALID) };
                at += BLOCK;
            } else {
                self.map_page(at, at, attrs)?;
                at += PAGE;
            }
        }
        Some(())
    }

    /// Turn translation on. Everything the kernel touches from here on
    /// must be mapped.
    pub fn enable(&self) {
        // Physical address size: what the CPU has, at most 48 bits.
        let mmfr0: u64;
        unsafe { asm!("mrs {}, id_aa64mmfr0_el1", out(reg) mmfr0) };
        let ips = (mmfr0 & 15).min(5);
        // T0SZ = 25 (39 bits), write-back caching for the walks, inner
        // shareable, 4 KiB granule, no TTBR1.
        let tcr: u64 = 25 | 1 << 8 | 1 << 10 | 3 << 12 | 1 << 23 | ips << 32;
        // Attribute 0: normal memory, write-back. Attribute 1: device.
        let mair: u64 = 0x04ff;
        // MMU, caches, stack alignment checks, and WXN: a writable page
        // is never executable, whatever its entry says. The rest are the
        // bits that must be one.
        let sctlr: u64 = 1 | 1 << 2 | 1 << 3 | 1 << 4 | 1 << 12 | 1 << 19
            | 1 << 11 | 1 << 20 | 1 << 22 | 1 << 23 | 1 << 28 | 1 << 29;
        unsafe {
            asm!(
                "msr mair_el1, {mair}",
                "msr tcr_el1, {tcr}",
                "msr ttbr0_el1, {root}",
                "isb",
                "tlbi vmalle1",
                "dsb nsh",
                "isb",
                "msr sctlr_el1, {sctlr}",
                "isb",
                mair = in(reg) mair,
                tcr = in(reg) tcr,
                root = in(reg) self.root,
                sctlr = in(reg) sctlr,
            )
        };
    }

    /// The physical address behind a page the program can read, or write
    /// if `write`. The tables are walked by hand, so a bad pointer in a
    /// system call is an error for the program and never a fault in the
    /// kernel.
    fn user_page(&self, va: u64, write: bool) -> Option<u64> {
        let mut table = self.root as *const u64;
        for shift in [30, 21] {
            let e = unsafe { table.add((va >> shift & 511) as usize).read() };
            if e & (VALID | TABLE) != VALID | TABLE {
                return None;
            }
            table = (e & ADDR) as *const u64;
        }
        let e = unsafe { table.add((va >> 12 & 511) as usize).read() };
        if e & VALID == 0 || e & AP_EL0 == 0 || (write && e & AP_RO != 0) {
            return None;
        }
        Some(e & ADDR)
    }

    /// Call `f` with each piece of the program's `len` bytes at `va`, as
    /// the kernel sees them. Returns false, having called nothing, unless
    /// the program may read (or write) every byte.
    pub fn with_user(&self, va: u64, len: u64, write: bool, mut f: impl FnMut(*mut u8, usize)) -> bool {
        let end = match va.checked_add(len) {
            Some(end) if va >= USER_BASE && end <= USER_END => end,
            _ => return false,
        };
        let mut page = va & !(PAGE - 1);
        while page < end {
            if self.user_page(page, write).is_none() {
                return false;
            }
            page += PAGE;
        }
        let mut at = va;
        while at < end {
            let n = (PAGE - at % PAGE).min(end - at);
            if let Some(pa) = self.user_page(at, write) {
                f((pa + at % PAGE) as *mut u8, n as usize);
            }
            at += n;
        }
        true
    }
}
