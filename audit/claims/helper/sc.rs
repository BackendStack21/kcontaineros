//! Audit helper (not part of the image): issue one raw aarch64 system call
//! and print what the kernel answered.
//!
//!   sc NR [ARG...]        ARG is a number (decimal or 0x hex), `s:TEXT` (pointer
//!                         to a NUL-terminated string) or `buf` (pointer to 4096
//!                         zero bytes)                 -> "ret=N" or "errno=N"
//!   sc clone FLAGS        clone(FLAGS|SIGCHLD); the child exits at once
//!   sc execmem            map a page read+write+exec, write "mov w0,#42; ret",
//!                         call it                      -> "execmem: 42"
//!   sc mq NAME            create a POSIX message queue with mq_open(2), store a
//!                         message in it, read it back, unlink it
//!   (any other name, or no arguments)   print "hello from NAME args=[...] uid=N"
//!   sc fileexec PATH      open PATH, mmap it PROT_READ|PROT_EXEC -> ret/errno
use std::arch::asm;
use std::ffi::CString;

fn sc(nr: usize, a: [usize; 6]) -> isize {
    let ret: isize;
    unsafe {
        asm!("svc 0", in("x8") nr, inlateout("x0") a[0] => ret, in("x1") a[1], in("x2") a[2],
             in("x3") a[3], in("x4") a[4], in("x5") a[5], options(nostack));
    }
    ret
}
fn num(s: &str) -> usize {
    if let Some(h) = s.strip_prefix("0x") { usize::from_str_radix(h, 16).unwrap() }
    else if let Some(n) = s.strip_prefix('-') { (-(n.parse::<isize>().unwrap())) as usize }
    else { s.parse().unwrap() }
}
fn show(r: isize) { if r < 0 && r > -4096 { println!("errno={}", -r) } else { println!("ret={}", r) } }

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // Under any other name (my-server, agent-tools) it stands in for "your program".
    let argv0 = std::env::args().next().unwrap();
    if !argv0.ends_with("sc") || args.is_empty() {
        println!("hello from {} args=[{}] uid={}", argv0.rsplit('/').next().unwrap(), args.join(" "), sc(174, [0; 6]));
        return;
    }
    match args[0].as_str() {
        "clone" => {
            let pid = sc(220, [num(&args[1]) | 17, 0, 0, 0, 0, 0]);
            if pid == 0 { sc(94, [0; 6]); }
            if pid > 0 { sc(260, [pid as usize, 0, 0, 0, 0, 0]); }
            show(pid);
        }
        "execmem" => {
            let p = sc(222, [0, 4096, 7, 0x22, usize::MAX, 0]);
            if p < 0 && p > -4096 { println!("execmem: mmap errno={}", -p); return; }
            let code: [u32; 2] = [0x52800540, 0xd65f03c0]; // mov w0,#42 ; ret
            unsafe {
                std::ptr::copy_nonoverlapping(code.as_ptr() as *const u8, p as *mut u8, 8);
                // make the new instructions visible: clean the data cache line,
                // invalidate the instruction cache line, synchronise
                asm!("dc cvau, {p}", "dsb ish", "ic ivau, {p}", "dsb ish", "isb", p = in(reg) p);
                let f: extern "C" fn() -> u32 = std::mem::transmute(p);
                println!("execmem: {}", f());
            }
        }
        "mq" => {
            // mq_open(O_CREAT|O_RDWR, 0600), mq_timedsend, mq_timedreceive, mq_unlink
            let name = CString::new(args[1].as_str()).unwrap();
            let fd = sc(180, [name.as_ptr() as usize, 0x42, 0o600, 0, 0, 0]);
            if fd < 0 { println!("mq_open errno={}", -fd); return; }
            let msg = b"stored";
            let s = sc(182, [fd as usize, msg.as_ptr() as usize, msg.len(), 0, 0, 0]);
            let mut back = [0u8; 8192];
            let r = sc(183, [fd as usize, back.as_mut_ptr() as usize, back.len(), 0, 0, 0]);
            let u = sc(181, [name.as_ptr() as usize, 0, 0, 0, 0, 0]);
            println!("mq_open ok, send={} receive={} ({}) unlink={}", s, r, String::from_utf8_lossy(&back[..r.max(0) as usize]), u);
        }
        "fileexec" => {
            let path = CString::new(args[1].as_str()).unwrap();
            let fd = sc(56, [(-100isize) as usize, path.as_ptr() as usize, 0, 0, 0, 0]);
            if fd < 0 { println!("open errno={}", -fd); return; }
            let p = sc(222, [0, 4096, 5, 2, fd as usize, 0]);
            if p < 0 && p > -4096 { println!("mmap-exec errno={}", -p) } else { println!("mmap-exec ok") }
        }
        _ => {
            let mut keep: Vec<CString> = Vec::new();
            let mut bytes: Vec<Vec<u8>> = Vec::new();
            let buf = vec![0u8; 4096];
            let mut a = [0usize; 6];
            for (i, s) in args[1..].iter().enumerate() {
                a[i] = if let Some(t) = s.strip_prefix("s:") { keep.push(CString::new(t).unwrap()); keep.last().unwrap().as_ptr() as usize }
                       else if let Some(h) = s.strip_prefix("x:") {
                           let b: Vec<u8> = (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap()).collect();
                           bytes.push(b); bytes.last().unwrap().as_ptr() as usize }
                       else if s == "buf" { buf.as_ptr() as usize } else { num(s) };
            }
            show(sc(num(&args[0]), a));
        }
    }
}
