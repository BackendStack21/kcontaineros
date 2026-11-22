//! The console: a PL011 UART, polled. Used by the bootloader and the
//! kernel; the program reaches it only through system calls.

use crate::layout::UART;
use crate::put;

const DR: usize = 0x00;
const FR: usize = 0x18;
const IBRD: usize = 0x24;
const FBRD: usize = 0x28;
const LCRH: usize = 0x2c;
const CR: usize = 0x30;
const IMSC: usize = 0x38;
const ICR: usize = 0x44;

const FR_RXFE: u32 = 1 << 4;
const FR_TXFF: u32 = 1 << 5;

fn rd(off: usize) -> u32 {
    unsafe { ((UART + off) as *const u32).read_volatile() }
}

fn wr(off: usize, v: u32) {
    unsafe { ((UART + off) as *mut u32).write_volatile(v) }
}

/// 115200 8N1 from a 24 MHz clock, no FIFO, no interrupts.
pub fn init() {
    wr(CR, 0);
    wr(ICR, 0x7ff);
    wr(IBRD, 13);
    wr(FBRD, 1);
    wr(LCRH, 0x60);
    wr(CR, 0x301);
}

/// Raise the interrupt line while a received byte is waiting. Nobody takes
/// the interrupt; it is what ends a `wfi`.
pub fn signal_rx() {
    wr(IMSC, 1 << 4);
}

fn putb(b: u8) {
    while rd(FR) & FR_TXFF != 0 {}
    wr(DR, b as u32);
}

/// Bytes to the console; a line feed gets its carriage return.
pub fn put(s: &[u8]) {
    for &b in s {
        if b == b'\n' {
            putb(b'\r');
        }
        putb(b);
    }
}

pub fn puts(s: &str) {
    put(s.as_bytes());
}

pub fn hex(v: u64) {
    put(put::hex(v, &mut [0; 18]));
}

pub fn dec(v: u64) {
    put(put::dec(v, &mut [0; 20]));
}

/// A received byte, if one is waiting.
pub fn getb() -> Option<u8> {
    if rd(FR) & FR_RXFE != 0 {
        None
    } else {
        Some(rd(DR) as u8)
    }
}
