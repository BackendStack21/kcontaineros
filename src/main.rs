//! kContainerOS — a zero-dependency mini OS userland for containers.
//!
//! One freestanding static binary (no libc, no std, no crates) that is:
//!   * `/sbin/init`  — a PID 1 that forwards signals and reaps zombies
//!   * `/bin/sh`     — a small shell (enough for `RUN`, `CMD` and entrypoints)
//!   * `/bin/<tool>` — a handful of core utilities
//!
//! The personality is selected by `argv[0]`, busybox-style. Whatever it is,
//! the process first locks itself down (see `lock.rs`).
//!
//! Without the default `tools` feature only PID 1 is built: that is the
//! "sealed" image, which has no shell and no utilities to misuse.
//!
//! The `cov` feature builds the same sources against std so that LLVM's
//! profiling runtime can be linked in; it exists only to measure coverage.

#![cfg_attr(not(feature = "cov"), no_std)]
#![no_main]
#![cfg_attr(not(feature = "tools"), allow(dead_code, unused_imports))]

extern crate alloc;

#[cfg(feature = "tools")]
mod applets;
mod init;
mod lock;
#[cfg(feature = "tools")]
mod sh;
mod sys;
mod util;

use alloc::vec::Vec;
use core::alloc::{GlobalAlloc, Layout};
use util::{basename, cstr, eprint, write_all};

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(not(target_arch = "aarch64"))]
compile_error!("kContainerOS supports ARM64 (aarch64) only");

// The kernel enters at _start with the stack pointer at argc. The binary is
// a static PIE, so it also needs to know where it was loaded.
#[cfg(not(feature = "cov"))]
core::arch::global_asm!(
    ".section .text._start,\"ax\"",
    ".globl _start",
    "_start:",
    "mov x29, #0",
    "mov x30, #0",
    "mov x0, sp",
    "adrp x1, __ehdr_start",
    "add x1, x1, :lo12:__ehdr_start",
    "adrp x2, _DYNAMIC",
    "add x2, x2, :lo12:_DYNAMIC",
    "bl kcos_start",
);

/// Self-relocation: nothing else will do it for a static PIE. Until this
/// returns, no code may read a pointer stored in the binary's data (string
/// tables, function tables), so it uses only its arguments and raw pointers.
#[cfg(not(feature = "cov"))]
#[no_mangle]
unsafe extern "C" fn kcos_start(sp: *const usize, base: usize, dynamic: *const [usize; 2]) -> ! {
    const DT_RELA: usize = 7;
    const DT_RELASZ: usize = 8;
    const R_AARCH64_RELATIVE: usize = 1027;
    const PT_GNU_RELRO: u32 = 0x6474_e552;
    const AT_PAGESZ: usize = 6;

    let (mut rela, mut rela_size) = (0, 0);
    let mut d = dynamic;
    while (*d)[0] != 0 {
        if (*d)[0] == DT_RELA {
            rela = (*d)[1];
        } else if (*d)[0] == DT_RELASZ {
            rela_size = (*d)[1];
        }
        d = d.add(1);
    }
    // Elf64_Rela { offset, info, addend }
    let mut r = (base + rela) as *const [usize; 3];
    let end = (base + rela + rela_size) as *const [usize; 3];
    while r < end {
        if (*r)[1] & 0xffff_ffff == R_AARCH64_RELATIVE {
            *((base + (*r)[0]) as *mut usize) = base + (*r)[2];
        }
        r = r.add(1);
    }

    // The relocated tables never change again: make them read-only (RELRO).
    let argc = *sp;
    let mut aux = sp.add(argc + 2);
    while *aux != 0 {
        aux = aux.add(1); // skip envp
    }
    aux = aux.add(1);
    let mut page = 4096;
    while *aux != 0 {
        if *aux == AT_PAGESZ {
            page = *aux.add(1);
        }
        aux = aux.add(2);
    }
    // Find the RELRO range and the segment that follows it.
    const PT_LOAD: u32 = 1;
    let phoff = *((base + 0x20) as *const usize);
    let phentsize = *((base + 0x36) as *const u16) as usize;
    let phnum = *((base + 0x38) as *const u16) as usize;
    let (mut relro, mut relro_end, mut next) = (0, 0, usize::MAX);
    let mut i = 0;
    while i < phnum {
        let ph = base + phoff + i * phentsize;
        if *(ph as *const u32) == PT_GNU_RELRO {
            relro = *((ph + 0x10) as *const usize);
            relro_end = relro + *((ph + 0x28) as *const usize);
        }
        i += 1;
    }
    i = 0;
    while i < phnum {
        let ph = base + phoff + i * phentsize;
        let vaddr = *((ph + 0x10) as *const usize);
        if *(ph as *const u32) == PT_LOAD && vaddr > relro && vaddr < next {
            next = vaddr;
        }
        i += 1;
    }
    // Whole pages only. Round the end up when that stays clear of the next
    // segment (it does with the linker's 64 KiB segment spacing), down
    // otherwise, so that writable data is never caught.
    let start = (base + relro) & !(page - 1);
    let mut stop = (base + relro_end + page - 1) & !(page - 1);
    if next != usize::MAX && stop > base + next {
        stop = (base + relro_end) & !(page - 1);
    }
    if stop > start {
        sys::mprotect_ro(start, stop - start);
    }

    kcos_main(sp)
}

unsafe fn kcos_main(sp: *const usize) -> ! {
    let argc = *sp;
    let argv = sp.add(1) as *const *const u8;
    let envp = argv.add(argc + 1);
    dispatch(argc, argv, envp)
}

/// The sealed build is PID 1 and nothing else, whatever it is called.
#[cfg(not(feature = "tools"))]
unsafe fn dispatch(_argc: usize, argv: *const *const u8, envp: *const *const u8) -> ! {
    init::run(argv.add(1), envp)
}

#[cfg(feature = "tools")]
unsafe fn dispatch(argc: usize, argv: *const *const u8, envp: *const *const u8) -> ! {
    let name: &[u8] = if argc > 0 { basename(cstr(*argv)) } else { b"kcontaineros" };
    if name == b"init" {
        init::run(argv.add(1), envp);
    }

    // Init locks itself down further than this; see `init::run`.
    lock::lockdown(envp, false);

    // `kcontaineros <applet> [args]` behaves like `<applet> [args]`.
    let mut first = 0;
    if name == b"kcontaineros" {
        let arg1: &[u8] = if argc > 1 { cstr(*argv.add(1)) } else { b"--help" };
        match arg1 {
            b"init" => init::run(argv.add(2), envp),
            b"--version" | b"-V" => {
                write_all(1, b"kcontaineros ");
                write_all(1, VERSION.as_bytes());
                write_all(1, b"\n");
                sys::exit(util::output_failed() as i32);
            }
            b"--list" => {
                let mut o = util::Out::new(1);
                o.s(b"init\nsh\n");
                for (n, _) in applets::LIST {
                    o.s(n);
                    o.s(b"\n");
                }
                o.flush();
                sys::exit(util::output_failed() as i32);
            }
            b"--help" | b"-h" => {
                write_all(1, b"usage: kcontaineros init [--] COMMAND [ARGS...]\n       kcontaineros APPLET [ARGS...]\n       kcontaineros --list | --version\n");
                sys::exit(util::output_failed() as i32);
            }
            _ => first = 1,
        }
    }

    let mut args: Vec<Vec<u8>> = (first..argc).map(|i| cstr(*argv.add(i)).to_vec()).collect();
    args[0] = basename(&args[0]).to_vec();
    let mut env: Vec<Vec<u8>> = Vec::new();
    let mut e = envp;
    while !(*e).is_null() {
        env.push(cstr(*e).to_vec());
        e = e.add(1);
    }

    let code = if &args[0][..] == b"sh" {
        sh::main(args, env)
    } else if let Some(code) = applets::run(&args, &env) {
        code
    } else {
        eprint(&[b"kcontaineros: ", &args[0], b": applet not found\n"]);
        127
    };
    sys::exit(code)
}

#[cfg(not(feature = "cov"))]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    write_all(2, b"kcontaineros: internal error\n");
    sys::exit(101)
}

/// Coverage builds link std for LLVM's profiling runtime, so libc's start
/// code runs first and calls `main`. `argv` still points into the stack the
/// kernel built, one word after argc, which is all `kcos_main` needs. Rust's
/// own runtime start-up is skipped, so nothing else differs from the real
/// binary: no descriptors are reopened and no signal dispositions change.
#[cfg(feature = "cov")]
#[no_mangle]
unsafe extern "C" fn main(_argc: i32, argv: *const *const u8) -> i32 {
    kcos_main((argv as *const usize).sub(1))
}

/// Size-class allocator over anonymous mmap chunks. Blocks are powers of
/// two from 16 bytes to 64 KiB, each class with its own free list and each
/// block aligned to its own size; anything larger gets its own mapping and
/// is unmapped when freed. Single-threaded by design: the binary never
/// creates a thread. `init` never allocates.
struct Heap;

const MIN_SHIFT: u32 = 4;
const MAX_SHIFT: u32 = 16;
const CHUNK: usize = 256 * 1024;
const PAGE: usize = 4096;

struct HeapState {
    free: [usize; (MAX_SHIFT - MIN_SHIFT + 1) as usize],
    cur: usize,
    end: usize,
}

static mut HEAP: HeapState = HeapState { free: [0; 13], cur: 0, end: 0 };

/// Free-list index for a layout, or None when it needs its own mapping.
fn class(l: &Layout) -> Option<usize> {
    let n = l.size().max(l.align()).max(1 << MIN_SHIFT);
    if n > 1 << MAX_SHIFT {
        return None;
    }
    Some((n.next_power_of_two().trailing_zeros() - MIN_SHIFT) as usize)
}

/// Map `len` bytes or stop the process: nothing here can continue without
/// memory, and a clear message beats a null-pointer fault.
fn map(len: usize) -> usize {
    let m = sys::mmap(len);
    if m < 0 && m > -4096 {
        write_all(2, b"kcontaineros: out of memory\n");
        sys::exit(101);
    }
    m as usize
}

unsafe impl GlobalAlloc for Heap {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let h = &mut *core::ptr::addr_of_mut!(HEAP);
        let Some(c) = class(&l) else {
            return map((l.size() + PAGE - 1) & !(PAGE - 1)) as *mut u8;
        };
        let head = h.free[c];
        if head != 0 {
            h.free[c] = *(head as *const usize);
            return head as *mut u8;
        }
        let size = 1usize << (c as u32 + MIN_SHIFT);
        let mask = size - 1;
        let mut p = (h.cur + mask) & !mask;
        if h.cur == 0 || p + size > h.end {
            h.cur = map(CHUNK);
            h.end = h.cur + CHUNK;
            p = (h.cur + mask) & !mask;
        }
        h.cur = p + size;
        p as *mut u8
    }

    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        let h = &mut *core::ptr::addr_of_mut!(HEAP);
        match class(&l) {
            Some(c) => {
                *(p as *mut usize) = h.free[c];
                h.free[c] = p as usize;
            }
            None => {
                sys::munmap(p as usize, (l.size() + PAGE - 1) & !(PAGE - 1));
            }
        }
    }

    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        let new_layout = Layout::from_size_align_unchecked(new, l.align());
        let old_class = class(&l);
        if old_class.is_some() && old_class == class(&new_layout) {
            return p; // still fits its block
        }
        let n = self.alloc(new_layout);
        core::ptr::copy_nonoverlapping(p, n, l.size().min(new));
        self.dealloc(p, l);
        n
    }
}

#[global_allocator]
static ALLOC: Heap = Heap;
