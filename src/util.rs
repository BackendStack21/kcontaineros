//! Small helpers shared by init, the shell and the applets.

use crate::sys;
use alloc::vec::Vec;

pub const DEFAULT_PATH: &[u8] = b"/usr/local/bin:/usr/bin:/bin:/sbin";

/// Borrow a NUL-terminated C string as a byte slice (without the NUL).
pub unsafe fn cstr<'a>(p: *const u8) -> &'a [u8] {
    let mut n = 0;
    while *p.add(n) != 0 {
        n += 1;
    }
    core::slice::from_raw_parts(p, n)
}

/// Copy `s` into a new NUL-terminated buffer.
pub fn cz(s: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(s.len() + 1);
    v.extend_from_slice(s);
    v.push(0);
    v
}

pub fn basename(p: &[u8]) -> &[u8] {
    match p.iter().rposition(|&c| c == b'/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}

pub fn join(dir: &[u8], name: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(dir.len() + name.len() + 1);
    v.extend_from_slice(dir);
    if !dir.ends_with(b"/") {
        v.push(b'/');
    }
    v.extend_from_slice(name);
    v
}

/// Set once a write to stdout fails (disk full, closed descriptor).
static mut OUTPUT_FAILED: bool = false;

pub fn output_failed() -> bool {
    unsafe { OUTPUT_FAILED }
}

pub fn write_all(fd: i32, b: &[u8]) -> bool {
    write_err(fd, b) == 0
}

/// Write all of `b`. Returns 0, or the negative errno that stopped it.
pub fn write_err(fd: i32, mut b: &[u8]) -> isize {
    while !b.is_empty() {
        let r = sys::write(fd, b);
        if r <= 0 {
            if fd == 1 {
                unsafe { OUTPUT_FAILED = true };
            }
            return if r == 0 { -5 } else { r };
        }
        b = &b[r as usize..];
    }
    0
}

/// Write a message to stderr. Not to a terminal: one writev(2) per eight
/// parts, so it is neither truncated nor interleaved with other writers.
/// To a terminal: with everything but printable ASCII replaced by `?`,
/// because the parts include names taken from arguments, the filesystem
/// and other processes, and none of those may drive the terminal. A
/// newline that ends a part is kept. Never allocates: init uses it.
pub fn eprint(parts: &[&[u8]]) {
    if sys::isatty(2) {
        let mut buf = [0u8; 512];
        let mut n = 0;
        for (k, part) in parts.iter().enumerate() {
            for (i, &c) in part.iter().enumerate() {
                // The newline that ends the message is the only one kept.
                let last = k + 1 == parts.len() && i + 1 == part.len();
                let keep = (0x20..0x7f).contains(&c) || (c == b'\n' && last);
                buf[n] = if keep { c } else { b'?' };
                n += 1;
                if n == buf.len() {
                    sys::write(2, &buf);
                    n = 0;
                }
            }
        }
        sys::write(2, &buf[..n]);
        return;
    }
    for group in parts.chunks(8) {
        let mut iov = [[0usize; 2]; 8];
        for (slot, part) in iov.iter_mut().zip(group) {
            *slot = [part.as_ptr() as usize, part.len()];
        }
        sys::writev(2, &iov[..group.len()]);
    }
}

/// Buffered writer; flushes on drop.
pub struct Out {
    fd: i32,
    n: usize,
    buf: [u8; 4096],
}

impl Out {
    pub fn new(fd: i32) -> Self {
        Out { fd, n: 0, buf: [0; 4096] }
    }

    pub fn s(&mut self, b: &[u8]) {
        if b.len() > self.buf.len() - self.n {
            self.flush();
            if b.len() >= self.buf.len() {
                write_all(self.fd, b);
                return;
            }
        }
        self.buf[self.n..self.n + b.len()].copy_from_slice(b);
        self.n += b.len();
    }

    /// Like `s`, with everything but printable ASCII replaced by `?`, so
    /// that a hostile file or process name cannot drive the terminal. That
    /// includes bytes above 0x7f: some of them are control codes too.
    pub fn safe(&mut self, b: &[u8]) {
        for &c in b {
            self.s(&[if (0x20..0x7f).contains(&c) { c } else { b'?' }]);
        }
    }

    pub fn num(&mut self, v: u64) {
        let mut tmp = [0u8; 20];
        self.s(fmt_u64(v, &mut tmp));
    }

    /// Right-aligned number, padded with spaces to `width`.
    pub fn num_w(&mut self, v: u64, width: usize) {
        let mut tmp = [0u8; 20];
        let d = fmt_u64(v, &mut tmp);
        for _ in d.len()..width {
            self.s(b" ");
        }
        self.s(d);
    }

    pub fn flush(&mut self) {
        write_all(self.fd, &self.buf[..self.n]);
        self.n = 0;
    }
}

impl Drop for Out {
    fn drop(&mut self) {
        self.flush();
    }
}

pub fn fmt_u64(mut v: u64, buf: &mut [u8; 20]) -> &[u8] {
    let mut i = buf.len();
    loop {
        i -= 1;
        buf[i] = b'0' + (v % 10) as u8;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    &buf[i..]
}

pub fn parse_u64(s: &[u8]) -> Option<u64> {
    if s.is_empty() {
        return None;
    }
    let mut v: u64 = 0;
    for &c in s {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((c - b'0') as u64)?;
    }
    Some(v)
}

/// Not kernel errnos: `cp` onto the file it is reading, and `rm -r` giving up.
pub const ESAMEFILE: isize = -4000;
pub const ETOODEEP: isize = -4001;

const ERRORS: &[(isize, &[u8])] = &[
    (1, b"operation not permitted"),
    (2, b"no such file or directory"),
    (3, b"no such process"),
    (5, b"input/output error"),
    (6, b"no such device or address"),
    (7, b"argument list too long"),
    (8, b"exec format error"),
    (9, b"bad file descriptor"),
    (11, b"resource temporarily unavailable"),
    (12, b"out of memory"),
    (13, b"permission denied"),
    (16, b"device or resource busy"),
    (17, b"file exists"),
    (18, b"cross-device link"),
    (19, b"no such device"),
    (20, b"not a directory"),
    (21, b"is a directory"),
    (22, b"invalid argument"),
    (23, b"too many open files in system"),
    (24, b"too many open files"),
    (26, b"text file busy"),
    (27, b"file too large"),
    (28, b"no space left on device"),
    (30, b"read-only file system"),
    (31, b"too many links"),
    (32, b"broken pipe"),
    (36, b"file name too long"),
    (39, b"directory not empty"),
    (40, b"too many levels of symbolic links"),
    (75, b"value too large"),
    (116, b"stale file handle"),
    (122, b"disk quota exceeded"),
    (4000, b"source and destination are the same file"),
    (4001, b"directory tree too deep"),
];

pub fn errstr(e: isize) -> &'static [u8] {
    ERRORS.iter().find(|(n, _)| *n == -e).map_or(b"error", |(_, text)| text)
}

pub fn getenv<'a>(env: &'a [Vec<u8>], key: &[u8]) -> Option<&'a [u8]> {
    env.iter()
        .find(|e| e.len() > key.len() && e.starts_with(key) && e[key.len()] == b'=')
        .map(|e| &e[key.len() + 1..])
}

/// execvp(3) without allocation: resolve `file` through `path` and exec it.
/// Only returns on failure, with the most meaningful `-errno`.
pub unsafe fn execvp(
    file: &[u8],
    argv: *const *const u8,
    envp: *const *const u8,
    path: &[u8],
) -> isize {
    let mut buf = [0u8; 4096];
    execvp_in(file, argv, envp, path, &mut buf)
}

/// `execvp` with the buffer the candidate paths are built in. When a file
/// was found but is not a program the kernel can run, the search stops
/// there with ENOEXEC and `buf` holds that file's path, NUL-terminated.
pub unsafe fn execvp_in(
    file: &[u8],
    argv: *const *const u8,
    envp: *const *const u8,
    path: &[u8],
    buf: &mut [u8; 4096],
) -> isize {
    if file.is_empty() {
        return sys::ENOENT;
    }
    if file.contains(&b'/') {
        if file.len() >= buf.len() {
            return -36;
        }
        buf[..file.len()].copy_from_slice(file);
        return sys::execve(buf.as_ptr(), argv, envp);
    }
    let mut err = sys::ENOENT;
    for dir in path.split(|&c| c == b':') {
        let dir: &[u8] = if dir.is_empty() { b"." } else { dir };
        let n = dir.len() + 1 + file.len();
        if n >= buf.len() {
            continue;
        }
        buf[..dir.len()].copy_from_slice(dir);
        buf[dir.len()] = b'/';
        buf[dir.len() + 1..n].copy_from_slice(file);
        buf[n] = 0;
        let e = sys::execve(buf.as_ptr(), argv, envp);
        if e == sys::ENOEXEC {
            return e;
        }
        if e != sys::ENOENT && e != sys::ENOTDIR {
            err = e;
        }
    }
    err
}

/// exec `args` with environment `env`, resolving through `$PATH`.
pub fn exec(args: &[Vec<u8>], env: &[Vec<u8>]) -> isize {
    exec_found(args, env, &mut Vec::new())
}

pub fn is_dir(path: &[u8]) -> bool {
    let mut st = [0u8; 256];
    // statx: mode is a u16 at offset 28.
    sys::statx(cz(path).as_ptr(), false, &mut st) == 0
        && u16::from_ne_bytes([st[28], st[29]]) & 0o170000 == 0o040000
}

/// `exec`; on ENOEXEC `found` is the file that could not be run.
pub fn exec_found(args: &[Vec<u8>], env: &[Vec<u8>], found: &mut Vec<u8>) -> isize {
    let argz: Vec<Vec<u8>> = args.iter().map(|a| cz(a)).collect();
    let envz: Vec<Vec<u8>> = env.iter().map(|e| cz(e)).collect();
    let mut argv: Vec<*const u8> = argz.iter().map(|a| a.as_ptr()).collect();
    let mut envp: Vec<*const u8> = envz.iter().map(|e| e.as_ptr()).collect();
    argv.push(core::ptr::null());
    envp.push(core::ptr::null());
    let path = getenv(env, b"PATH").unwrap_or(DEFAULT_PATH);
    let mut buf = [0u8; 4096];
    let e = unsafe { execvp_in(&args[0], argv.as_ptr(), envp.as_ptr(), path, &mut buf) };
    if e == sys::ENOEXEC {
        found.extend_from_slice(unsafe { cstr(buf.as_ptr()) });
    }
    e
}

pub fn read_file(path: &[u8]) -> Result<Vec<u8>, isize> {
    let fd = sys::open(cz(path).as_ptr(), sys::O_RDONLY, 0);
    if fd < 0 {
        return Err(fd);
    }
    let fd = fd as i32;
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    let res = loop {
        let n = sys::read(fd, &mut buf);
        if n <= 0 {
            break n;
        }
        out.extend_from_slice(&buf[..n as usize]);
    };
    sys::close(fd);
    if res < 0 {
        return Err(res);
    }
    Ok(out)
}

/// List the names in a directory, without "." and "..".
pub fn read_dir(path: &[u8]) -> Result<Vec<Vec<u8>>, isize> {
    let fd = sys::open(cz(path).as_ptr(), sys::O_RDONLY | sys::O_DIRECTORY, 0);
    if fd < 0 {
        return Err(fd);
    }
    let names = read_dir_fd(fd as i32);
    sys::close(fd as i32);
    names
}

/// Like `read_dir`, for a directory that is already open. A directory that
/// stops being readable part-way is an error, never a shorter listing.
pub fn read_dir_fd(fd: i32) -> Result<Vec<Vec<u8>>, isize> {
    let mut out = Vec::new();
    while read_dir_some(fd, &mut out)? {}
    Ok(out)
}

/// Append the next few names of the open directory `fd` to `out`; false at
/// the end. For callers that must not hold a huge directory in memory.
pub fn read_dir_some(fd: i32, out: &mut Vec<Vec<u8>>) -> Result<bool, isize> {
    let mut buf = [0u8; 4096];
    let n = sys::getdents(fd, &mut buf);
    if n < 0 {
        return Err(n);
    }
    let mut p = 0;
    while p < n as usize {
        // struct linux_dirent64 { u64 ino; i64 off; u16 reclen; u8 type; char name[]; }
        let reclen = u16::from_ne_bytes([buf[p + 16], buf[p + 17]]) as usize;
        let raw = &buf[p + 19..p + reclen];
        let name = &raw[..raw.iter().position(|&c| c == 0).unwrap_or(raw.len())];
        if name != b"." && name != b".." {
            out.push(name.to_vec());
        }
        p += reclen;
    }
    Ok(n > 0)
}

/// Translate a wait status into a shell-style exit code.
pub fn exit_code(status: i32) -> i32 {
    if status & 0x7f == 0 {
        (status >> 8) & 0xff
    } else {
        128 + (status & 0x7f)
    }
}
