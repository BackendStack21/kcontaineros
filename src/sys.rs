//! Raw Linux syscalls for aarch64 (ARM64). No libc.
//!
//! Every wrapper returns the kernel's raw result: `>= 0` on success,
//! `-errno` on failure. Path arguments must be NUL-terminated.
//!
//! No signal handler is ever installed (signals are ignored, defaulted or
//! consumed with `rt_sigtimedwait`), so the kernel restarts interrupted
//! calls itself and callers do not loop on `EINTR`.

use core::arch::asm;

mod nr {
    pub const GETCWD: usize = 17;
    pub const DUP3: usize = 24;
    pub const FCNTL: usize = 25;
    pub const IOCTL: usize = 29;
    pub const MKDIRAT: usize = 34;
    pub const UNLINKAT: usize = 35;
    pub const SYMLINKAT: usize = 36;
    pub const LINKAT: usize = 37;
    pub const FACCESSAT: usize = 48;
    pub const CHDIR: usize = 49;
    pub const FCHMODAT: usize = 53;
    pub const FCHOWNAT: usize = 54;
    pub const OPENAT: usize = 56;
    pub const CLOSE: usize = 57;
    pub const PIPE2: usize = 59;
    pub const GETDENTS64: usize = 61;
    pub const READ: usize = 63;
    pub const WRITE: usize = 64;
    pub const WRITEV: usize = 66;
    pub const READLINKAT: usize = 78;
    pub const UTIMENSAT: usize = 88;
    pub const CAPSET: usize = 91;
    pub const EXIT_GROUP: usize = 94;
    pub const NANOSLEEP: usize = 101;
    pub const CLOCK_GETTIME: usize = 113;
    pub const KILL: usize = 129;
    pub const RT_SIGACTION: usize = 134;
    pub const RT_SIGPROCMASK: usize = 135;
    pub const RT_SIGTIMEDWAIT: usize = 137;
    pub const SETPGID: usize = 154;
    pub const GETPGID: usize = 155;
    pub const UNAME: usize = 160;
    pub const UMASK: usize = 166;
    pub const PRCTL: usize = 167;
    pub const GETPID: usize = 172;
    pub const GETPPID: usize = 173;
    pub const GETUID: usize = 174;
    pub const GETEUID: usize = 175;
    pub const MUNMAP: usize = 215;
    pub const CLONE: usize = 220;
    pub const EXECVE: usize = 221;
    pub const MMAP: usize = 222;
    #[cfg(not(feature = "cov"))]
    pub const MPROTECT: usize = 226;
    pub const WAIT4: usize = 260;
    pub const RENAMEAT2: usize = 276;
    pub const SECCOMP: usize = 277;
    pub const STATX: usize = 291;
    pub const LANDLOCK_CREATE_RULESET: usize = 444;
    pub const LANDLOCK_ADD_RULE: usize = 445;
    pub const LANDLOCK_RESTRICT_SELF: usize = 446;
}

#[inline(always)]
unsafe fn sc(n: usize, a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) -> isize {
    let ret: isize;
    asm!(
        "svc 0",
        in("x8") n,
        inlateout("x0") a => ret,
        in("x1") b, in("x2") c, in("x3") d, in("x4") e, in("x5") f,
        options(nostack)
    );
    ret
}

const CWD: usize = -100isize as usize;

pub const O_RDONLY: usize = 0;
pub const O_WRONLY: usize = 1;
pub const O_CREAT: usize = 0o100;
pub const O_TRUNC: usize = 0o1000;
pub const O_APPEND: usize = 0o2000;
pub const O_NONBLOCK: usize = 0o4000;
pub const O_DIRECTORY: usize = 0o40000;
pub const O_NOFOLLOW: usize = 0o100000;
pub const O_CLOEXEC: usize = 0o2000000;
pub const O_PATH: usize = 0o10000000;

/// "Relative to the current directory" for the `*at` calls.
pub const AT_FDCWD: i32 = -100;

pub const ENOENT: isize = -2;
pub const EBADF: isize = -9;
pub const ECHILD: isize = -10;
pub const EEXIST: isize = -17;
pub const ENOTDIR: isize = -20;
pub const EISDIR: isize = -21;
pub const ENOEXEC: isize = -8;

pub const SIGINT: usize = 2;
pub const SIGQUIT: usize = 3;
pub const SIGCHLD: usize = 17;
pub const WNOHANG: usize = 1;
pub const WUNTRACED: usize = 2;

pub fn read(fd: i32, buf: &mut [u8]) -> isize {
    unsafe { sc(nr::READ, fd as usize, buf.as_mut_ptr() as usize, buf.len(), 0, 0, 0) }
}

pub fn write(fd: i32, buf: &[u8]) -> isize {
    unsafe { sc(nr::WRITE, fd as usize, buf.as_ptr() as usize, buf.len(), 0, 0, 0) }
}

pub fn open(path: *const u8, flags: usize, mode: usize) -> isize {
    openat(AT_FDCWD, path, flags, mode)
}

pub fn openat(dirfd: i32, path: *const u8, flags: usize, mode: usize) -> isize {
    unsafe { sc(nr::OPENAT, dirfd as usize, path as usize, flags, mode, 0, 0) }
}

pub fn close(fd: i32) -> isize {
    unsafe { sc(nr::CLOSE, fd as usize, 0, 0, 0, 0, 0) }
}

pub fn execve(path: *const u8, argv: *const *const u8, envp: *const *const u8) -> isize {
    #[cfg(feature = "cov")]
    {
        // Skip the dump when no descriptor is free: it could only fail noisily.
        let probe = open(b"/\0".as_ptr(), O_RDONLY, 0);
        if probe >= 0 {
            close(probe as i32);
            cov_dump();
        }
    }
    unsafe { sc(nr::EXECVE, path as usize, argv as usize, envp as usize, 0, 0, 0) }
}

pub fn exit(code: i32) -> ! {
    #[cfg(feature = "cov")]
    {
        close(0); // a free descriptor, so the dump works at the fd limit too
        cov_dump();
    }
    loop {
        unsafe { sc(nr::EXIT_GROUP, code as usize, 0, 0, 0, 0, 0) };
    }
}

/// fork(2), implemented as clone(SIGCHLD): the child runs on a
/// copy-on-write copy of the parent's stack.
pub fn fork() -> isize {
    unsafe { sc(nr::CLONE, SIGCHLD, 0, 0, 0, 0, 0) }
}

pub fn wait4(pid: isize, status: &mut i32, opts: usize) -> isize {
    unsafe { sc(nr::WAIT4, pid as usize, status as *mut i32 as usize, opts, 0, 0, 0) }
}

pub fn kill(pid: isize, sig: usize) -> isize {
    unsafe { sc(nr::KILL, pid as usize, sig, 0, 0, 0, 0) }
}

pub fn getppid() -> isize {
    unsafe { sc(nr::GETPPID, 0, 0, 0, 0, 0, 0) }
}

pub fn getpid() -> isize {
    unsafe { sc(nr::GETPID, 0, 0, 0, 0, 0, 0) }
}

pub fn geteuid() -> isize {
    unsafe { sc(nr::GETEUID, 0, 0, 0, 0, 0, 0) }
}

pub fn getuid() -> isize {
    unsafe { sc(nr::GETUID, 0, 0, 0, 0, 0, 0) }
}

/// sigprocmask(SIG_SETMASK, set, old)
pub fn sigsetmask(set: &u64, old: Option<&mut u64>) -> isize {
    let old = old.map_or(0, |o| o as *mut u64 as usize);
    unsafe { sc(nr::RT_SIGPROCMASK, 2, set as *const u64 as usize, old, 8, 0, 0) }
}

/// sigprocmask(SIG_BLOCK, set, old)
pub fn sigblock(set: &u64, old: &mut u64) -> isize {
    unsafe { sc(nr::RT_SIGPROCMASK, 0, set as *const u64 as usize, old as *mut u64 as usize, 8, 0, 0) }
}

/// Wait until one of the signals in `set` is pending and return its number.
/// With a timeout (in nanoseconds, below one second) returns `-EAGAIN` when
/// it elapses.
pub fn sigwait(set: &u64, timeout_ns: Option<u64>) -> isize {
    let mut info = [0u8; 128];
    let ts = [0u64, timeout_ns.unwrap_or(0)];
    let tsp = if timeout_ns.is_some() { ts.as_ptr() as usize } else { 0 };
    unsafe {
        sc(nr::RT_SIGTIMEDWAIT, set as *const u64 as usize, info.as_mut_ptr() as usize, tsp, 8, 0, 0)
    }
}

/// Set a signal disposition to SIG_DFL (0) or SIG_IGN (1).
pub fn signal(sig: usize, disposition: usize) -> isize {
    // The kernel's struct sigaction is {handler, flags, restorer, mask}.
    let act = [disposition, 0, 0, 0];
    unsafe { sc(nr::RT_SIGACTION, sig, act.as_ptr() as usize, 0, 8, 0, 0) }
}

pub fn setpgid(pid: isize, pgid: isize) -> isize {
    unsafe { sc(nr::SETPGID, pid as usize, pgid as usize, 0, 0, 0, 0) }
}

/// The caller's own process group.
pub fn getpgid() -> isize {
    unsafe { sc(nr::GETPGID, 0, 0, 0, 0, 0, 0) }
}

pub fn ioctl(fd: i32, req: usize, arg: usize) -> isize {
    unsafe { sc(nr::IOCTL, fd as usize, req, arg, 0, 0, 0) }
}

pub fn isatty(fd: i32) -> bool {
    let mut termios = [0u8; 64];
    ioctl(fd, 0x5401 /* TCGETS */, termios.as_mut_ptr() as usize) == 0
}

pub fn prctl(op: usize, arg: usize) -> isize {
    unsafe { sc(nr::PRCTL, op, arg, 0, 0, 0, 0) }
}

/// Set the file mode creation mask; returns the previous one.
pub fn umask(mask: usize) -> isize {
    unsafe { sc(nr::UMASK, mask, 0, 0, 0, 0, 0) }
}

/// 0 if `path` may be executed by this process.
pub fn access_x(path: *const u8) -> isize {
    unsafe { sc(nr::FACCESSAT, CWD, path as usize, 1 /* X_OK */, 0, 0, 0) }
}

pub fn chdir(path: *const u8) -> isize {
    unsafe { sc(nr::CHDIR, path as usize, 0, 0, 0, 0, 0) }
}

/// Returns the length including the trailing NUL.
pub fn getcwd(buf: &mut [u8]) -> isize {
    unsafe { sc(nr::GETCWD, buf.as_mut_ptr() as usize, buf.len(), 0, 0, 0, 0) }
}

pub fn getdents(fd: i32, buf: &mut [u8]) -> isize {
    unsafe { sc(nr::GETDENTS64, fd as usize, buf.as_mut_ptr() as usize, buf.len(), 0, 0, 0) }
}

pub fn pipe(fds: &mut [i32; 2]) -> isize {
    unsafe { sc(nr::PIPE2, fds.as_mut_ptr() as usize, 0, 0, 0, 0, 0) }
}

pub fn dup3(old: i32, new: i32) -> isize {
    unsafe { sc(nr::DUP3, old as usize, new as usize, 0, 0, 0, 0) }
}

/// Anonymous private read/write mapping.
pub fn mmap(len: usize) -> isize {
    unsafe { sc(nr::MMAP, 0, len, 3, 0x22, usize::MAX, 0) }
}

pub fn munmap(addr: usize, len: usize) -> isize {
    unsafe { sc(nr::MUNMAP, addr, len, 0, 0, 0, 0) }
}

/// Make `[addr, addr + len)` read-only.
#[cfg(not(feature = "cov"))]
pub fn mprotect_ro(addr: usize, len: usize) -> isize {
    unsafe { sc(nr::MPROTECT, addr, len, 1, 0, 0, 0) }
}

/// Write several buffers with one syscall, so a message is not interleaved
/// with other writers. `iov` is an array of (pointer, length) pairs.
pub fn writev(fd: i32, iov: &[[usize; 2]]) -> isize {
    unsafe { sc(nr::WRITEV, fd as usize, iov.as_ptr() as usize, iov.len(), 0, 0, 0) }
}

/// Clear O_NONBLOCK (and the other status flags) on `fd`.
pub fn set_blocking(fd: i32) -> isize {
    unsafe { sc(nr::FCNTL, fd as usize, 4 /* F_SETFL */, 0, 0, 0, 0) }
}

/// Duplicate `fd` onto the lowest free descriptor >= `min`, close-on-exec.
pub fn dup_above(fd: i32, min: i32) -> isize {
    unsafe { sc(nr::FCNTL, fd as usize, 1030 /* F_DUPFD_CLOEXEC */, min as usize, 0, 0, 0) }
}

/// statx(2), used instead of stat because its layout is fixed and
/// documented. uid: u32 @20, gid: u32 @24, mode: u16 @28, ino: u64 @32,
/// size: u64 @40, dev major/minor: u32 @136/@140.
pub fn statx(path: *const u8, nofollow: bool, buf: &mut [u8; 256]) -> isize {
    let flags = if nofollow { 0x100 } else { 0 };
    unsafe { sc(nr::STATX, CWD, path as usize, flags, 0x7ff, buf.as_mut_ptr() as usize, 0) }
}

/// statx(2) of an open descriptor.
pub fn fstatx(fd: i32, buf: &mut [u8; 256]) -> isize {
    let empty_path = 0x1000;
    unsafe {
        sc(nr::STATX, fd as usize, b"\0".as_ptr() as usize, empty_path, 0x7ff, buf.as_mut_ptr() as usize, 0)
    }
}

pub fn mkdir(path: *const u8, mode: usize) -> isize {
    unsafe { sc(nr::MKDIRAT, CWD, path as usize, mode, 0, 0, 0) }
}

/// Remove `path` relative to `dirfd`: a directory if `rmdir`, else anything
/// that is not a directory.
pub fn unlinkat(dirfd: i32, path: *const u8, rmdir: bool) -> isize {
    let flags = if rmdir { 0x200 } else { 0 };
    unsafe { sc(nr::UNLINKAT, dirfd as usize, path as usize, flags, 0, 0, 0) }
}

pub fn rename(old: *const u8, new: *const u8) -> isize {
    unsafe { sc(nr::RENAMEAT2, CWD, old as usize, CWD, new as usize, 0, 0) }
}

pub fn symlink(target: *const u8, link: *const u8) -> isize {
    unsafe { sc(nr::SYMLINKAT, target as usize, CWD, link as usize, 0, 0, 0) }
}

pub fn link(old: *const u8, new: *const u8) -> isize {
    unsafe { sc(nr::LINKAT, CWD, old as usize, CWD, new as usize, 0, 0) }
}

pub fn chmod(path: *const u8, mode: usize) -> isize {
    unsafe { sc(nr::FCHMODAT, CWD, path as usize, mode, 0, 0, 0) }
}

/// Change owner and group; `u32::MAX` leaves one of them as it is.
pub fn chown(path: *const u8, uid: u32, gid: u32) -> isize {
    unsafe { sc(nr::FCHOWNAT, CWD, path as usize, uid as usize, gid as usize, 0, 0) }
}

/// Set atime/mtime of `path` to now.
pub fn utimes_now(path: *const u8) -> isize {
    unsafe { sc(nr::UTIMENSAT, CWD, path as usize, 0, 0, 0, 0) }
}

pub fn readlink(path: *const u8, buf: &mut [u8]) -> isize {
    unsafe {
        sc(nr::READLINKAT, CWD, path as usize, buf.as_mut_ptr() as usize, buf.len(), 0, 0)
    }
}

pub fn nanosleep(sec: u64, nsec: u64) -> isize {
    let ts = [sec, nsec];
    unsafe { sc(nr::NANOSLEEP, ts.as_ptr() as usize, 0, 0, 0, 0, 0) }
}

/// Milliseconds on the monotonic clock.
pub fn monotonic_ms() -> u64 {
    let mut ts = [0u64; 2];
    unsafe { sc(nr::CLOCK_GETTIME, 1, ts.as_mut_ptr() as usize, 0, 0, 0, 0) };
    ts[0] * 1000 + ts[1] / 1_000_000
}

/// Fills a `struct utsname`: six 65-byte NUL-terminated fields.
pub fn uname(buf: &mut [u8; 390]) -> isize {
    unsafe { sc(nr::UNAME, buf.as_mut_ptr() as usize, 0, 0, 0, 0, 0) }
}

/// Install a seccomp filter: `prog` is a `struct sock_fprog`, that is
/// (instruction count, pointer to the instructions).
pub fn seccomp_filter(prog: &[usize; 2]) -> isize {
    unsafe { sc(nr::SECCOMP, 1 /* SECCOMP_SET_MODE_FILTER */, 0, prog.as_ptr() as usize, 0, 0, 0) }
}

/// Set this thread's effective, permitted and inheritable capability sets.
/// `header` and `data` are the kernel's `__user_cap_header_struct` and two
/// `__user_cap_data_struct`.
pub fn capset(header: &[u32; 2], data: &[u32; 6]) -> isize {
    unsafe { sc(nr::CAPSET, header.as_ptr() as usize, data.as_ptr() as usize, 0, 0, 0, 0) }
}

/// The Landlock version this kernel implements, or a negative errno.
pub fn landlock_abi() -> isize {
    let version = 1; // LANDLOCK_CREATE_RULESET_VERSION
    unsafe { sc(nr::LANDLOCK_CREATE_RULESET, 0, 0, version, 0, 0, 0) }
}

/// Create a Landlock ruleset handling the filesystem rights in `handled`.
pub fn landlock_create_ruleset(handled: &u64) -> isize {
    unsafe { sc(nr::LANDLOCK_CREATE_RULESET, handled as *const u64 as usize, 8, 0, 0, 0, 0) }
}

/// Add a "path beneath" rule: `rule` is a packed (allowed rights: u64,
/// directory descriptor: i32).
pub fn landlock_add_rule(ruleset: i32, rule: &[u8; 12]) -> isize {
    let path_beneath = 1;
    unsafe {
        sc(nr::LANDLOCK_ADD_RULE, ruleset as usize, path_beneath, rule.as_ptr() as usize, 0, 0, 0)
    }
}

pub fn landlock_restrict_self(ruleset: i32) -> isize {
    unsafe { sc(nr::LANDLOCK_RESTRICT_SELF, ruleset as usize, 0, 0, 0, 0, 0) }
}

/// Coverage builds only: write this process's counters to
/// /cov/<pid>-<nanos>.profraw. Called before exit and before exec, the two
/// ways a process image ends.
#[cfg(feature = "cov")]
fn cov_dump() {
    extern "C" {
        fn __llvm_profile_set_filename(name: *const u8);
        fn __llvm_profile_write_file() -> i32;
    }
    static mut NAME: [u8; 64] = [0; 64];
    let mut ts = [0u64; 2];
    unsafe { sc(nr::CLOCK_GETTIME, 1, ts.as_mut_ptr() as usize, 0, 0, 0, 0) };
    let name = unsafe { &mut *core::ptr::addr_of_mut!(NAME) };
    let mut n = 0;
    let mut tmp = [0u8; 20];
    let pid = crate::util::fmt_u64(getpid() as u64, &mut tmp).to_vec();
    let nanos = crate::util::fmt_u64(ts[0] * 1_000_000_000 + ts[1], &mut tmp).to_vec();
    for part in [&b"/cov/"[..], &pid, b"-", &nanos, b".profraw\0"] {
        name[n..n + part.len()].copy_from_slice(part);
        n += part.len();
    }
    unsafe {
        __llvm_profile_set_filename(name.as_ptr());
        __llvm_profile_write_file();
    }
}
