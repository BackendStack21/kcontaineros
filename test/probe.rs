//! Test helper, not part of the image: issue system calls the lockdown must
//! refuse and print what the kernel answered. Built statically and placed
//! in the test image by test/e2e.sh.
//!
//!     probe memfd_create ptrace ...    ->   "memfd_create: errno 1" ...

use std::arch::asm;

fn syscall(nr: usize, a: usize, b: usize) -> isize {
    let ret: isize;
    unsafe {
        asm!("svc 0", in("x8") nr, inlateout("x0") a => ret, in("x1") b,
             in("x2") 0usize, in("x3") 0usize, in("x4") 0usize, in("x5") 0usize, options(nostack));
    }
    ret
}

fn main() {
    const SIGCHLD: usize = 17;
    const CLONE_NEWUSER: usize = 0x1000_0000;
    for name in std::env::args().skip(1) {
        let ret = match name.as_str() {
            "memfd_create" => syscall(279, b"x\0".as_ptr() as usize, 0),
            "memfd_secret" => syscall(447, 0, 0),
            // Give this one last: where it is allowed the process is traced
            // from then on, and any signal would stop it for a tracer that
            // never comes.
            "ptrace" => syscall(117, 0 /* PTRACE_TRACEME */, 0),
            "process_vm_readv" => syscall(270, 1, 0),
            "io_uring_setup" => syscall(425, 1, 0),
            "bpf" => syscall(280, 0, 0),
            "userfaultfd" => syscall(282, 0, 0),
            "clone3" => syscall(435, 0, 0),
            "vsock" => syscall(198, 40 /* AF_VSOCK */, 1 /* SOCK_STREAM */),
            "socket" => syscall(198, 2 /* AF_INET */, 1),
            // One past the newest system call the filter knows about.
            "newer_than_filter" => syscall(467, 0, 0),
            "clone_newuser" => {
                let pid = syscall(220, CLONE_NEWUSER | SIGCHLD, 0);
                if pid == 0 {
                    std::process::exit(0); // the child, if it was allowed
                }
                if pid > 0 {
                    syscall(260, pid as usize, 0); // wait4: its SIGCHLD ends here
                }
                pid
            }
            _ => {
                println!("{name}: unknown probe");
                continue;
            }
        };
        if ret >= 0 {
            println!("{name}: allowed");
        } else {
            println!("{name}: errno {}", -ret);
        }
    }
}
