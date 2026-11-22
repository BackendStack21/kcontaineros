//! The first and only program: a command line on the console, at EL0. It
//! can do nothing but compute and make system calls; the commands that
//! reach for more are there to show what the kernel does about it.
#![no_std]
#![no_main]

use core::arch::{asm, global_asm};
use core::panic::PanicInfo;
use kcos_bare::abi::*;
use kcos_bare::put;

global_asm!(
    r#"
    .section .text.start, "ax"
    .global _start
_start:
    bl main
    "#
);

fn sys(nr: u64, a0: u64, a1: u64) -> i64 {
    let ret: i64;
    unsafe { asm!("svc #0", in("x8") nr, inout("x0") a0 => ret, in("x1") a1, options(nostack)) };
    ret
}

fn out(s: &[u8]) {
    sys(SYS_WRITE, s.as_ptr() as u64, s.len() as u64);
}

fn exit(status: u64) -> ! {
    sys(SYS_EXIT, status, 0);
    loop {}
}

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    out(b"init: panic\n");
    exit(1)
}

const HELP: &[u8] = b"\
echo [WORD]...     print the words
info               memory, as the kernel reports it
sys NR [A0 [A1]]   make system call NR (decimal) with hexadecimal arguments
peek ADDR          read the byte at a hexadecimal address
poke ADDR          write a zero byte there
jump ADDR          call the code there
el                 read CurrentEL, which only the kernel may
fp                 use a floating point register
exit [STATUS]      end init: the machine powers off
help               this list
";

fn usage(text: &[u8]) {
    out(b"init: usage: ");
    out(text);
    out(b"\n");
}

fn run(line: &[u8]) {
    let mut words = line.split(|&b| b == b' ').filter(|w| !w.is_empty());
    let Some(cmd) = words.next() else { return };
    // echo takes any number of words and prints them as it goes. For the
    // others three are kept, and all are counted.
    let mut args = [&b""[..]; 3];
    let mut argc = 0;
    for word in words {
        if cmd == b"echo" {
            if argc > 0 {
                out(b" ");
            }
            out(word);
        } else if argc < args.len() {
            args[argc] = word;
        }
        argc += 1;
    }
    let args = &args[..argc.min(3)];
    let hex = |i: usize| put::parse_hex(args[i]);
    match (cmd, argc) {
        (b"echo", _) => out(b"\n"),
        (b"help", 0) => out(HELP),
        (b"help", _) => usage(b"help"),
        (b"info", 0) => {
            let mut info = [0u64; 2];
            sys(SYS_INFO, info.as_mut_ptr() as u64, 0);
            out(b"ram ");
            out(put::dec(info[0] >> 20, &mut [0; 20]));
            out(b" MiB, free ");
            out(put::dec(info[1] >> 20, &mut [0; 20]));
            out(b" MiB\n");
        }
        (b"info", _) => usage(b"info"),
        (b"sys", 1..=3) => {
            let nr = put::parse_dec(args[0]);
            let a0 = if args.len() > 1 { hex(1) } else { Some(0) };
            let a1 = if args.len() > 2 { hex(2) } else { Some(0) };
            let (Some(nr), Some(a0), Some(a1)) = (nr, a0, a1) else {
                return usage(b"sys NR [A0 [A1]]");
            };
            let ret = sys(nr, a0, a1);
            if ret < 0 {
                out(b"-");
            }
            out(put::dec(ret.unsigned_abs(), &mut [0; 20]));
            out(b"\n");
        }
        (b"sys", _) => usage(b"sys NR [A0 [A1]]"),
        (b"peek" | b"poke" | b"jump", 1) => {
            let Some(addr) = hex(0) else {
                out(b"init: ");
                out(cmd);
                return out(b": the address must be hexadecimal digits\n");
            };
            match cmd {
                b"peek" => {
                    let byte = unsafe { (addr as *const u8).read_volatile() };
                    out(put::hex(byte as u64, &mut [0; 18]));
                    out(b"\n");
                }
                b"poke" => {
                    unsafe { (addr as *mut u8).write_volatile(0) };
                    out(b"written\n");
                }
                _ => {
                    unsafe { asm!("blr {}", in(reg) addr, clobber_abi("C")) };
                    out(b"returned\n");
                }
            }
        }
        (b"peek", _) => usage(b"peek ADDR"),
        (b"poke", _) => usage(b"poke ADDR"),
        (b"jump", _) => usage(b"jump ADDR"),
        (b"el", 0) => {
            let el: u64;
            unsafe { asm!("mrs {}, CurrentEL", out(reg) el) };
            out(put::dec(el >> 2, &mut [0; 20]));
            out(b"\n");
        }
        (b"el", _) => usage(b"el"),
        (b"fp", 0) => {
            // fmov d0, xzr, spelled out: this build has no floating point.
            unsafe { asm!(".inst 0x9e6703e0") };
            out(b"used\n");
        }
        (b"fp", _) => usage(b"fp"),
        (b"exit", 0) => exit(0),
        (b"exit", 1) => match put::parse_dec(args[0]) {
            Some(status) if status <= 255 => exit(status),
            _ => usage(b"exit [STATUS], from 0 to 255"),
        },
        (b"exit", _) => usage(b"exit [STATUS], from 0 to 255"),
        _ => {
            out(b"init: ");
            out(cmd);
            out(b": not found\n");
        }
    }
}

#[no_mangle]
extern "C" fn main() -> ! {
    let mut line = [0u8; 128];
    let mut len = 0;
    // The line no longer fits: what follows is dropped up to its end.
    let mut over = false;
    out(b"$ ");
    loop {
        let mut c = [0u8];
        if sys(SYS_READ, c.as_mut_ptr() as u64, 1) != 1 {
            out(b"init: cannot read the console\n");
            exit(1);
        }
        match c[0] {
            b'\r' | b'\n' => {
                out(b"\n");
                if over {
                    out(b"init: line too long\n");
                } else {
                    run(&line[..len]);
                }
                (len, over) = (0, false);
                out(b"$ ");
            }
            // ^C: forget the line.
            3 => {
                out(b"^C\n$ ");
                (len, over) = (0, false);
            }
            // ^D on an empty line: done.
            4 if len == 0 && !over => {
                out(b"\n");
                exit(0);
            }
            // Backspace, as either of the two bytes terminals send.
            8 | 0x7f if len > 0 && !over => {
                len -= 1;
                out(b"\x08 \x08");
            }
            0x20..=0x7e if len < line.len() => {
                line[len] = c[0];
                len += 1;
                out(&c);
            }
            0x20..=0x7e => over = true,
            _ => {}
        }
    }
}
