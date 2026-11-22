//! Core utilities (cat, ls, cp, ...) built on raw syscalls.

use crate::sys;
use crate::util::*;
use alloc::vec::Vec;

pub type Applet = fn(args: &[Vec<u8>], env: &[Vec<u8>]) -> i32;

pub const LIST: &[(&[u8], Applet)] = &[
    (b"cat", cat),
    (b"chmod", chmod),
    (b"chown", chown),
    (b"cp", cp),
    (b"echo", echo),
    (b"env", env),
    (b"false", false_),
    (b"kill", kill),
    (b"ln", ln),
    (b"ls", ls),
    (b"mkdir", mkdir),
    (b"mv", mv),
    (b"ps", ps),
    (b"pwd", pwd),
    (b"rm", rm),
    (b"sleep", sleep),
    (b"touch", touch),
    (b"true", true_),
    (b"uname", uname),
];

/// Run the applet named by `args[0]`, or None if there is no such applet.
/// An applet that could not write its output fails, whatever it returned.
pub fn run(args: &[Vec<u8>], env: &[Vec<u8>]) -> Option<i32> {
    let applet = LIST.iter().find(|(n, _)| *n == &args[0][..])?.1;
    let code = applet(args, env);
    Some(if code == 0 && output_failed() { 1 } else { code })
}

// ---------------------------------------------------------------- helpers

const S_IFMT: u32 = 0o170000;
const S_IFCHR: u32 = 0o020000;
const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;
const S_IFLNK: u32 = 0o120000;

/// Print `name: operand: <errstr>` to stderr and return exit status 1.
fn fail(name: &[u8], op: &[u8], e: isize) -> i32 {
    eprint(&[name, b": ", op, b": ", errstr(e), b"\n"]);
    1
}

/// Parse leading `-xyz` option clusters (`--` ends them). Returns the flag
/// characters seen and the index of the first operand.
fn flags(name: &[u8], a: &[Vec<u8>], allowed: &[u8]) -> Option<(Vec<u8>, usize)> {
    let mut f = Vec::new();
    let mut i = 1;
    while i < a.len() {
        let s = &a[i][..];
        if s == b"--" {
            i += 1;
            break;
        }
        if s.len() < 2 || s[0] != b'-' {
            break;
        }
        for &c in &s[1..] {
            if !allowed.contains(&c) {
                eprint(&[name, b": invalid option: ", s, b"\n"]);
                return None;
            }
            f.push(c);
        }
        i += 1;
    }
    Some((f, i))
}

struct Stat {
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    /// (device major, device minor, inode): identifies the file itself
    id: (u32, u32, u64),
}

/// Describe the file at `path`, or the open descriptor `fd` if there is one.
fn stat_of(path: &[u8], nofollow: bool, fd: Option<i32>) -> Result<Stat, isize> {
    let mut b = [0u8; 256];
    let r = match fd {
        Some(fd) => sys::fstatx(fd, &mut b),
        None => sys::statx(cz(path).as_ptr(), nofollow, &mut b),
    };
    if r < 0 {
        return Err(r);
    }
    let u32_at = |o: usize| u32::from_ne_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]);
    let u64_at = |o: usize| (u32_at(o) as u64) | (u32_at(o + 4) as u64) << 32;
    Ok(Stat {
        mode: u32_at(28) & 0xffff,
        uid: u32_at(20),
        gid: u32_at(24),
        size: u64_at(40),
        id: (u32_at(136), u32_at(140), u64_at(32)),
    })
}

/// `p` without its trailing slashes (empty for "/" and "").
fn trim_slashes(p: &[u8]) -> &[u8] {
    match p.iter().rposition(|&c| c != b'/') {
        Some(last) => &p[..=last],
        None => &p[..0],
    }
}

fn stat(path: &[u8], nofollow: bool) -> Result<Stat, isize> {
    stat_of(path, nofollow, None)
}

fn is_dir(path: &[u8]) -> bool {
    matches!(stat(path, false), Ok(s) if s.mode & S_IFMT == S_IFDIR)
}

// ------------------------------------------------------------------ cat

/// Copy `from` to `to` until end of file. Returns 0 or a negative errno,
/// and whether it was the writing that failed.
fn pump_between(from: i32, to: i32) -> (isize, bool) {
    let mut buf = [0u8; 65536];
    loop {
        let n = sys::read(from, &mut buf);
        if n <= 0 {
            return (n, false);
        }
        let w = write_err(to, &buf[..n as usize]);
        if w < 0 {
            return (w, true);
        }
    }
}

fn cat(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let stdin = [b"-".to_vec()];
    let Some((_, first)) = flags(b"cat", a, b"") else {
        return 1;
    };
    let files: &[Vec<u8>] = if first < a.len() { &a[first..] } else { &stdin };
    let mut rc = 0;
    for f in files {
        let (r, writing) = if &f[..] == b"-" {
            pump_between(0, 1)
        } else {
            let fd = sys::open(cz(f).as_ptr(), sys::O_RDONLY, 0);
            if fd >= 0 {
                let r = pump_between(fd as i32, 1);
                sys::close(fd as i32);
                r
            } else {
                (fd, false)
            }
        };
        if writing {
            // Nothing more can be written: say so once and stop.
            return fail(b"cat", b"write error", r);
        }
        if r < 0 {
            rc = fail(b"cat", f, r);
        }
    }
    rc
}

// ---------------------------------------------------------------- chmod

fn chmod(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let Some((_, first)) = flags(b"chmod", a, b"") else {
        return 1;
    };
    // The files start after the mode, and after a `--` that may follow it.
    let files = first + 1 + a.get(first + 1).is_some_and(|s| &s[..] == b"--") as usize;
    if a.len() <= files {
        eprint(&[b"chmod: usage: chmod OCTAL FILE...\n"]);
        return 1;
    }
    let spec = &a[first];
    if spec.is_empty() || spec.len() > 4 || spec.iter().any(|c| !(b'0'..=b'7').contains(c)) {
        eprint(&[b"chmod: invalid mode: ", spec, b"\n"]);
        return 1;
    }
    let mode = spec.iter().fold(0, |m, &c| m * 8 + (c - b'0') as usize);
    let mut rc = 0;
    for f in &a[files..] {
        let r = sys::chmod(cz(f).as_ptr(), mode);
        if r < 0 {
            rc = fail(b"chmod", f, r);
        }
    }
    rc
}

// ---------------------------------------------------------------- chown

/// chown UID[:GID] FILE...   Numeric IDs only: there is no user database
/// worth consulting in an image with two accounts.
fn chown(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let Some((_, first)) = flags(b"chown", a, b"") else {
        return 1;
    };
    // The files start after the owner, and after a `--` that may follow it.
    let files = first + 1 + a.get(first + 1).is_some_and(|s| &s[..] == b"--") as usize;
    if a.len() <= files {
        eprint(&[b"chown: usage: chown UID[:GID] FILE...\n"]);
        return 1;
    }
    let spec = &a[first];
    let (user, group) = match spec.iter().position(|&c| c == b':') {
        Some(i) => (&spec[..i], Some(&spec[i + 1..])),
        None => (&spec[..], None),
    };
    let id = |s: &[u8]| parse_u64(s).filter(|&n| n < u32::MAX as u64).map(|n| n as u32);
    let (Some(uid), Some(gid)) = (id(user), group.map_or(Some(u32::MAX), id)) else {
        eprint(&[b"chown: invalid owner: ", spec, b"\n"]);
        return 1;
    };
    let mut rc = 0;
    for f in &a[files..] {
        let r = sys::chown(cz(f).as_ptr(), uid, gid);
        if r < 0 {
            rc = fail(b"chown", f, r);
        }
    }
    rc
}

// ------------------------------------------------------------- cp and mv

/// What went wrong in a copy or move, and whether the destination (rather
/// than the source) is the path to name in the message.
type Failure = (isize, bool);

fn copy_file(src: &[u8], dst: &[u8]) -> Result<(), Failure> {
    // Open first and inspect the descriptor, so the file checked is the
    // file copied. O_NONBLOCK keeps a FIFO from blocking the open.
    let fd = sys::open(cz(src).as_ptr(), sys::O_RDONLY | sys::O_NONBLOCK, 0);
    if fd < 0 {
        return Err((fd, false));
    }
    let fd = fd as i32;
    let res = (|| {
        let s = stat_of(b"", false, Some(fd)).map_err(|e| (e, false))?;
        match s.mode & S_IFMT {
            S_IFREG | S_IFCHR => {} // a device too: `cp /dev/null file`
            S_IFDIR => return Err((sys::EISDIR, false)),
            _ => return Err((-22, false)),
        }
        if matches!(stat(dst, false), Ok(d) if d.id == s.id) {
            return Err((ESAMEFILE, false)); // opening it would truncate the source
        }
        // Permission bits only: a copy never inherits setuid, setgid or sticky.
        let flags = sys::O_WRONLY | sys::O_CREAT | sys::O_TRUNC;
        let out = sys::open(cz(dst).as_ptr(), flags, (s.mode & 0o777) as usize);
        if out < 0 {
            return Err((out, true));
        }
        // The open was non-blocking only so that a FIFO could not hang it.
        sys::set_blocking(fd);
        let (r, writing) = pump_between(fd, out as i32);
        let closed = sys::close(out as i32);
        if r < 0 {
            return Err((r, writing));
        }
        if closed < 0 {
            return Err((closed, true)); // a write the filesystem had deferred
        }
        Ok(())
    })();
    sys::close(fd);
    res
}

fn move_file(src: &[u8], dst: &[u8]) -> Result<(), Failure> {
    let r = sys::rename(cz(src).as_ptr(), cz(dst).as_ptr());
    if r < 0 {
        // "No such file" about a source that exists is about the destination.
        // So is "is a directory" about a source that is not one.
        let source = stat(src, true);
        let at_destination = match r {
            sys::ENOENT | sys::ENOTDIR => source.is_ok(),
            sys::EISDIR => source.is_ok_and(|s| s.mode & S_IFMT != S_IFDIR),
            _ => false,
        };
        return Err((r, at_destination));
    }
    Ok(())
}

/// Shared driver for `cp` and `mv`: SRC... DST, into DST if it is a directory.
fn transfer(name: &[u8], a: &[Vec<u8>], op: fn(&[u8], &[u8]) -> Result<(), Failure>) -> i32 {
    let Some((_, first)) = flags(name, a, b"") else {
        return 1;
    };
    let a = &a[first..];
    let Some((dst, sources)) = a.split_last().filter(|(_, sources)| !sources.is_empty()) else {
        eprint(&[name, b": usage: ", name, b" SRC... DST\n"]);
        return 1;
    };
    let dir = is_dir(dst);
    if sources.len() > 1 && !dir {
        return fail(name, dst, sys::ENOTDIR);
    }
    let mut rc = 0;
    for s in sources {
        let target = if dir {
            // "a/" goes into the directory under the name "a".
            let leaf = basename(trim_slashes(s));
            if matches!(leaf, b"" | b"." | b"..") {
                rc = fail(name, s, -22);
                continue;
            }
            join(dst, leaf)
        } else {
            dst.clone()
        };
        if let Err((e, at_destination)) = op(s, &target) {
            rc = fail(name, if at_destination { &target } else { s }, e);
        }
    }
    rc
}

fn cp(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    transfer(b"cp", a, copy_file)
}

fn mv(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    transfer(b"mv", a, move_file)
}

// ------------------------------------------------- echo, env, true, false

/// echo [-neE] [ARG...]   Leading words made only of those letters are
/// options; `-e` turns on the backslash escapes of POSIX echo.
fn echo(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let (mut newline, mut escapes, mut start) = (true, false, 1);
    while let Some(opt) = a.get(start).filter(|s| s.len() > 1 && s[0] == b'-') {
        if opt[1..].iter().any(|c| !matches!(c, b'n' | b'e' | b'E')) {
            break;
        }
        for &c in &opt[1..] {
            match c {
                b'n' => newline = false,
                b'e' => escapes = true,
                _ => escapes = false,
            }
        }
        start += 1;
    }
    let mut o = Out::new(1);
    'args: for (i, s) in a.iter().skip(start).enumerate() {
        if i > 0 {
            o.s(b" ");
        }
        if !escapes {
            o.s(s);
            continue;
        }
        let mut k = 0;
        while k < s.len() {
            let c = s[k];
            k += 1;
            if c != b'\\' || k == s.len() {
                o.s(&[c]);
                continue;
            }
            let e = s[k];
            k += 1;
            let byte = match e {
                b'n' => b'\n',
                b't' => b'\t',
                b'r' => b'\r',
                b'a' => 7,
                b'b' => 8,
                b'e' => 27,
                b'f' => 12,
                b'v' => 11,
                b'\\' => b'\\',
                b'c' => {
                    newline = false;
                    break 'args; // \c: nothing more, not even the newline
                }
                b'0' | b'x' => {
                    // \0NNN octal (up to three digits), \xHH hexadecimal.
                    let (radix, max) = if e == b'0' { (8, 3) } else { (16, 2) };
                    let (mut v, mut n) = (0u32, 0);
                    while n < max && k < s.len() {
                        let Some(d) = (s[k] as char).to_digit(radix) else { break };
                        v = v * radix + d;
                        k += 1;
                        n += 1;
                    }
                    if e == b'x' && n == 0 {
                        o.s(b"\\x");
                        continue;
                    }
                    v as u8
                }
                other => {
                    o.s(&[b'\\', other]);
                    continue;
                }
            };
            o.s(&[byte]);
        }
    }
    if newline {
        o.s(b"\n");
    }
    0
}

/// env [-i] [NAME=VALUE]... [COMMAND [ARGS]...]
fn env(a: &[Vec<u8>], e: &[Vec<u8>]) -> i32 {
    let mut vars: Vec<Vec<u8>> = e.to_vec();
    let mut i = 1;
    // env [-i | -] [-u NAME]... [--]
    while let Some(opt) = a.get(i).filter(|s| s.first() == Some(&b'-')) {
        i += 1;
        match &opt[..] {
            b"--" => break,
            b"-i" | b"-" => vars.clear(),
            b"-u" if i < a.len() => {
                let name = &a[i];
                vars.retain(|v| !(v.starts_with(name) && v.get(name.len()) == Some(&b'=')));
                i += 1;
            }
            _ => {
                eprint(&[b"env: invalid option: ", opt, b"\n"]);
                return 1;
            }
        }
    }
    while let Some(eq) = a.get(i).and_then(|s| s.iter().position(|&c| c == b'=')).filter(|&p| p > 0) {
        vars.retain(|v| !v.starts_with(&a[i][..=eq]));
        vars.push(a[i].clone());
        i += 1;
    }
    if i < a.len() {
        let err = exec(&a[i..], &vars);
        fail(b"env", &a[i], err);
        return if err == sys::ENOENT || err == sys::ENOTDIR { 127 } else { 126 };
    }
    let mut o = Out::new(1);
    let tty = sys::isatty(1);
    for v in &vars {
        if tty {
            o.safe(v);
        } else {
            o.s(v);
        }
        o.s(b"\n");
    }
    0
}

fn false_(_a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    1
}

fn true_(_a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    0
}

// ----------------------------------------------------------------- kill

const SIGNALS: &[(&[u8], u64)] = &[
    (b"HUP", 1),
    (b"INT", 2),
    (b"QUIT", 3),
    (b"KILL", 9),
    (b"USR1", 10),
    (b"USR2", 12),
    (b"TERM", 15),
    (b"CONT", 18),
    (b"STOP", 19),
];

fn kill(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let mut sig = 15;
    let mut i = 1;
    if a.len() > 1 && a[1].len() > 1 && a[1][0] == b'-' && &a[1][..] != b"--" {
        // -SIGNAL, or -s SIGNAL
        let two = &a[1][..] == b"-s" && a.len() > 2;
        let s = if two { &a[2][..] } else { &a[1][1..] };
        let s = s.strip_prefix(b"SIG").unwrap_or(s);
        let named = SIGNALS.iter().find(|(n, _)| *n == s).map(|&(_, v)| v);
        sig = match named.or_else(|| parse_u64(s)) {
            Some(n) if n <= 64 => n,
            _ => {
                eprint(&[b"kill: invalid signal: ", &a[1 + two as usize], b"\n"]);
                return 1;
            }
        };
        i = 2 + two as usize;
    }
    if a.get(i).is_some_and(|s| &s[..] == b"--") {
        i += 1;
    }
    if i >= a.len() {
        eprint(&[b"kill: usage: kill [-SIGNAL] PID...\n"]);
        return 1;
    }
    let mut rc = 0;
    for p in &a[i..] {
        // Only real process IDs: 0, -1 and other "everything" forms are
        // refused, as is anything that would wrap around a 32-bit pid_t.
        match parse_u64(p) {
            Some(pid) if (1..=i32::MAX as u64).contains(&pid) => {
                let r = sys::kill(pid as isize, sig as usize);
                if r < 0 {
                    rc = fail(b"kill", p, r);
                }
            }
            _ => {
                eprint(&[b"kill: invalid pid: ", p, b"\n"]);
                rc = 1;
            }
        }
    }
    rc
}

// ------------------------------------------------------------------- ln

fn ln(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let Some((f, i)) = flags(b"ln", a, b"s") else {
        return 1;
    };
    if a.len() != i + 2 {
        eprint(&[b"ln: usage: ln [-s] TARGET LINK\n"]);
        return 1;
    }
    let (t, l) = (cz(&a[i]), cz(&a[i + 1]));
    let r = if f.contains(&b's') {
        sys::symlink(t.as_ptr(), l.as_ptr())
    } else {
        sys::link(t.as_ptr(), l.as_ptr())
    };
    if r < 0 {
        // A hard link to something that is not there: name what is missing.
        let missing = !f.contains(&b's') && r == sys::ENOENT && stat(&a[i], true).is_err();
        return fail(b"ln", &a[if missing { i } else { i + 1 }], r);
    }
    0
}

// ------------------------------------------------------------------- ls

struct Ls {
    out: Out,
    long: bool,
    /// Replace control characters in names: on when stdout is a terminal.
    safe: bool,
}

impl Ls {
    fn name(&mut self, n: &[u8]) {
        if self.safe {
            self.out.safe(n);
        } else {
            self.out.s(n);
        }
    }

    /// Print one entry; `full` is the path to stat, `name` what to show.
    /// `member` is true for a name read from a directory: one that has
    /// vanished since is skipped, as it would be had it gone a moment sooner.
    fn entry(&mut self, full: &[u8], name: &[u8], member: bool) -> i32 {
        if !self.long && member {
            self.name(name);
            self.out.s(b"\n");
            return 0;
        }
        let st = match stat(full, true) {
            Ok(s) => s,
            Err(e) if member && e == sys::ENOENT => return 0,
            Err(e) => {
                self.out.flush();
                return fail(b"ls", full, e);
            }
        };
        if !self.long {
            self.name(name);
            self.out.s(b"\n");
            return 0;
        }
        let m = st.mode;
        let mut s = [b'-'; 10];
        // File type from the top four mode bits.
        s[0] = b"?pc?d?b?-?l?s???"[(m >> 12) as usize & 15];
        for k in 0..9 {
            if m & (0o400 >> k) != 0 {
                s[1 + k] = b"rwx"[k % 3];
            }
        }
        // setuid, setgid and sticky replace the matching execute position.
        for (bit, pos, set) in [(0o4000, 3, b's'), (0o2000, 6, b's'), (0o1000, 9, b't')] {
            if m & bit != 0 {
                s[pos] = if s[pos] == b'x' { set } else { set.to_ascii_uppercase() };
            }
        }
        self.out.s(&s);
        for n in [st.uid as u64, st.gid as u64, st.size] {
            self.out.s(b" ");
            self.out.num(n);
        }
        self.out.s(b" ");
        self.name(name);
        if m & S_IFMT == S_IFLNK {
            let mut buf = [0u8; 4096];
            let r = sys::readlink(cz(full).as_ptr(), &mut buf);
            if r < 0 {
                self.out.s(b"\n");
                self.out.flush();
                return fail(b"ls", full, r);
            }
            self.out.s(b" -> ");
            self.name(&buf[..r as usize]);
        }
        self.out.s(b"\n");
        0
    }
}

fn ls(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let Some((f, i)) = flags(b"ls", a, b"la") else {
        return 1;
    };
    let all = f.contains(&b'a');
    let mut ls = Ls { out: Out::new(1), long: f.contains(&b'l'), safe: sys::isatty(1) };
    let dot = [b".".to_vec()];
    let paths: &[Vec<u8>] = if i < a.len() { &a[i..] } else { &dot };
    let mut rc = 0;
    let mut listed = false;
    for p in paths {
        match read_dir(p) {
            Ok(mut entries) => {
                // Several operands: a header for each, a blank line between.
                if paths.len() > 1 {
                    if listed {
                        ls.out.s(b"\n");
                    }
                    ls.name(p);
                    ls.out.s(b":\n");
                }
                listed = true;
                if all {
                    entries.push(b".".to_vec());
                    entries.push(b"..".to_vec());
                }
                entries.sort_unstable();
                for n in &entries {
                    if all || n[0] != b'.' {
                        rc |= ls.entry(&join(p, n), n, true);
                    }
                }
            }
            // A file, or a symlink whose target cannot be looked at,
            // whatever the reason: show the thing itself.
            Err(e)
                if e == sys::ENOTDIR
                    || (stat(p, true).is_ok_and(|s| s.mode & S_IFMT == S_IFLNK) && stat(p, false).is_err()) =>
            {
                rc |= ls.entry(p, p, false)
            }
            Err(e) => {
                ls.out.flush();
                rc = fail(b"ls", p, e);
            }
        }
    }
    rc
}

// ---------------------------------------------------------------- mkdir

fn mkdir(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let Some((f, i)) = flags(b"mkdir", a, b"p") else {
        return 1;
    };
    if i >= a.len() {
        eprint(&[b"mkdir: missing operand\n"]);
        return 1;
    }
    let parents = f.contains(&b'p');
    let mask = sys::umask(0) as usize;
    sys::umask(mask);
    let mut rc = 0;
    for d in &a[i..] {
        // With -p, create each prefix that ends at a slash, then the whole.
        let mut ends: Vec<usize> = Vec::new();
        if parents {
            ends.extend((1..d.len()).filter(|&k| d[k] == b'/'));
        }
        ends.push(d.len());
        for &k in &ends {
            // A parent made here must let its owner go on, whatever the
            // umask: it is created that way, not repaired afterwards, when
            // the name could be something else already.
            let parent = d[k..].iter().any(|&c| c != b'/');
            if parent {
                sys::umask(mask & !0o300);
            }
            let r = sys::mkdir(cz(&d[..k]).as_ptr(), 0o777);
            if parent {
                sys::umask(mask);
            }
            if r < 0 && !(parents && r == sys::EEXIST && is_dir(&d[..k])) {
                rc = fail(b"mkdir", &d[..k], r);
                break;
            }
        }
    }
    rc
}

// ------------------------------------------------------------------- ps

fn ps(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    if a.len() > 1 {
        eprint(&[b"ps: usage: ps\n"]);
        return 1;
    }
    let entries = match read_dir(b"/proc") {
        Ok(x) => x,
        Err(e) => return fail(b"ps", b"/proc", e),
    };
    let mut pids: Vec<u64> = entries.iter().filter_map(|n| parse_u64(n)).collect();
    pids.sort_unstable();
    let mut o = Out::new(1);
    o.s(b"  PID S COMMAND\n");
    for pid in pids {
        let mut tmp = [0u8; 20];
        let dir = join(b"/proc", fmt_u64(pid, &mut tmp));
        // A process can vanish between the listing and the read.
        let Ok(st) = read_file(&join(&dir, b"stat")) else { continue };
        // "pid (comm) state ...": comm may itself contain parentheses, so
        // take the first "(" and the last ")".
        let open = st.iter().position(|&c| c == b'(').unwrap_or(0);
        let close = st.iter().rposition(|&c| c == b')').unwrap_or(0).max(open);
        let state = st.get(close + 2).copied().unwrap_or(b'?');
        let mut cmd = read_file(&join(&dir, b"cmdline")).unwrap_or_default();
        while cmd.last() == Some(&0) {
            cmd.pop();
        }
        for c in cmd.iter_mut().filter(|c| **c == 0) {
            *c = b' ';
        }
        o.num_w(pid, 5);
        o.s(b" ");
        o.safe(&[state]);
        o.s(b" ");
        // Names and arguments are chosen by the process: never print them raw.
        if cmd.is_empty() {
            o.s(b"[");
            o.safe(&st[(open + 1).min(close)..close]);
            o.s(b"]");
        } else {
            o.safe(&cmd);
        }
        o.s(b"\n");
    }
    0
}

// ------------------------------------------------------------------ pwd

fn pwd(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    if a.len() > 1 {
        eprint(&[b"pwd: usage: pwd\n"]);
        return 1;
    }
    let mut buf = [0u8; 4096];
    let r = sys::getcwd(&mut buf);
    if r < 0 {
        return fail(b"pwd", b".", r);
    }
    let mut o = Out::new(1);
    // A directory name is someone else's choice: not raw on a terminal.
    if sys::isatty(1) {
        o.safe(&buf[..r as usize - 1]);
    } else {
        o.s(&buf[..r as usize - 1]);
    }
    o.s(b"\n");
    0
}

// ------------------------------------------------------------------- rm

/// How many directories deep `rm -r` will go. Each level holds a
/// descriptor and a stack frame, so this bounds both; a small stack limit
/// lowers it further (see `rm`).
const RM_MAX_DEPTH: usize = 4096;
/// More than a level of the walk needs on the stack.
const RM_FRAME: usize = 512;

struct Rm {
    rec: bool,
    force: bool,
    max_depth: usize,
    /// Full path of what is being removed, for messages only.
    shown: Vec<u8>,
}

impl Rm {
    /// Remove `name` inside the directory `dirfd`. Recursion goes through
    /// directory descriptors opened without following symlinks, so the walk
    /// cannot be redirected outside the tree and has no path-length limit.
    fn at(&mut self, dirfd: i32, name: &[u8], depth: usize) -> i32 {
        let nz = cz(name);
        let r = sys::unlinkat(dirfd, nz.as_ptr(), false);
        if r >= 0 || (r == sys::ENOENT && self.force) {
            return 0;
        }
        if !self.rec || r == sys::ENOENT || r == sys::ENOTDIR {
            return fail(b"rm", &self.shown, r);
        }
        // Whatever the error, a directory is still emptied as far as it can
        // be: in a parent that cannot be written the kernel says "permission
        // denied" before it says "is a directory".
        let flags = sys::O_RDONLY | sys::O_DIRECTORY | sys::O_NOFOLLOW;
        let fd = sys::openat(dirfd, nz.as_ptr(), flags, 0);
        if fd < 0 {
            return fail(b"rm", &self.shown, if r == sys::EISDIR { fd } else { r });
        }
        if depth >= self.max_depth {
            sys::close(fd as i32);
            return fail(b"rm", &self.shown, ETOODEEP);
        }
        let mut rc = 0;
        let len = self.shown.len();
        // A few names at a time: a directory can hold more than memory does.
        let mut names = Vec::new();
        loop {
            match read_dir_some(fd as i32, &mut names) {
                Ok(true) => {}
                Ok(false) => break,
                Err(e) => {
                    rc = fail(b"rm", &self.shown, e);
                    break;
                }
            }
            for n in names.drain(..) {
                self.shown.push(b'/');
                self.shown.extend_from_slice(&n);
                rc |= self.at(fd as i32, &n, depth + 1);
                self.shown.truncate(len);
            }
        }
        sys::close(fd as i32);
        if rc != 0 {
            return rc; // already reported; the directory is not empty
        }
        let r = sys::unlinkat(dirfd, nz.as_ptr(), true);
        if r < 0 {
            rc = fail(b"rm", &self.shown, r);
        }
        rc
    }
}

fn rm(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let Some((f, i)) = flags(b"rm", a, b"rf") else {
        return 1;
    };
    let (rec, force) = (f.contains(&b'r'), f.contains(&b'f'));
    if i >= a.len() && !force {
        eprint(&[b"rm: missing operand\n"]);
        return 1;
    }
    // Half of the stack, at most, for the walk.
    let max_depth = RM_MAX_DEPTH.min(sys::stack_limit() / 2 / RM_FRAME);
    let mut rc = 0;
    for p in &a[i..] {
        // "/", "." and ".." (with any trailing slashes) are never removed.
        // (An empty operand is not "/": it is a file that does not exist.)
        if !p.is_empty() && matches!(basename(trim_slashes(p)), b"" | b"." | b"..") {
            eprint(&[b"rm: refusing to remove ", p, b"\n"]);
            rc = 1;
            continue;
        }
        // Without its trailing slashes: with one the kernel follows a link
        // even where it was told not to. "link/" stays what it was, though:
        // not a directory to remove.
        let name = if p.is_empty() { &p[..] } else { trim_slashes(p) };
        if name.len() < p.len() && stat(name, true).is_ok_and(|s| s.mode & S_IFMT != S_IFDIR) {
            rc = fail(b"rm", p, sys::ENOTDIR);
            continue;
        }
        let mut rm = Rm { rec, force, max_depth, shown: p.clone() };
        rc |= rm.at(sys::AT_FDCWD, name, 0);
    }
    rc
}

// ---------------------------------------------------------------- sleep

/// sleep SECONDS...   Decimal fractions allowed; several operands add up.
fn sleep(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let Some((_, first)) = flags(b"sleep", a, b"") else {
        return 1;
    };
    if first >= a.len() {
        eprint(&[b"sleep: usage: sleep SECONDS...\n"]);
        return 1;
    }
    let (mut total, mut total_ns) = (0u64, 0u64);
    for arg in &a[first..] {
        if matches!(&arg[..], b"infinity" | b"inf") {
            loop {
                sys::nanosleep(1 << 30, 0);
            }
        }
        // A unit may follow: s (the default), m, h or d.
        let unit = match arg.last() {
            Some(b'm') => 60,
            Some(b'h') => 3600,
            Some(b'd') => 86400,
            _ => 1,
        };
        let s = match arg.last() {
            Some(b's' | b'm' | b'h' | b'd') if arg.len() > 1 => &arg[..arg.len() - 1],
            _ => &arg[..],
        };
        let (whole, frac) = match s.iter().position(|&c| c == b'.') {
            Some(i) => (&s[..i], &s[i + 1..]),
            None => (&s[..], &s[..0]),
        };
        let sec = if whole.is_empty() && !frac.is_empty() { Some(0) } else { parse_u64(whole) };
        // Nanoseconds from up to nine fractional digits.
        let ns = (0..9).fold(0, |ns, k| ns * 10 + frac.get(k).map_or(0, |&c| (c - b'0').min(9) as u64));
        let sum = sec.filter(|_| frac.iter().all(u8::is_ascii_digit)).and_then(|sec| {
            // In nanoseconds times the unit: at most 86400 seconds' worth.
            let ns = total_ns + ns * unit;
            total.checked_add(sec.checked_mul(unit)?)?.checked_add(ns / 1_000_000_000).map(|t| (t, ns % 1_000_000_000))
        });
        let Some((t, ns)) = sum else {
            eprint(&[b"sleep: invalid time interval: ", arg, b"\n"]);
            return 1;
        };
        (total, total_ns) = (t, ns);
    }
    let r = sys::nanosleep(total, total_ns);
    if r < 0 {
        return fail(b"sleep", &a[first], r);
    }
    0
}

// ---------------------------------------------------------------- touch

fn touch(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let Some((_, first)) = flags(b"touch", a, b"") else {
        return 1;
    };
    if first >= a.len() {
        eprint(&[b"touch: missing file operand\n"]);
        return 1;
    }
    let mut rc = 0;
    for f in &a[first..] {
        let p = cz(f);
        // Update the times of whatever is there (a directory too); only
        // create a file when nothing is.
        let mut r = sys::utimes_now(p.as_ptr());
        if r == sys::ENOENT {
            r = sys::open(p.as_ptr(), sys::O_WRONLY | sys::O_CREAT, 0o666);
            if r >= 0 {
                sys::close(r as i32);
            }
        }
        if r < 0 {
            rc = fail(b"touch", f, r);
        }
    }
    rc
}

// --------------------------------------------------------------- uname

fn uname(a: &[Vec<u8>], _e: &[Vec<u8>]) -> i32 {
    let mut b = [0u8; 390];
    sys::uname(&mut b);
    // struct utsname: sysname, nodename, release, version, machine.
    let field = |i: usize| {
        let f = &b[i * 65..(i + 1) * 65];
        &f[..f.iter().position(|&c| c == 0).unwrap_or(f.len())]
    };
    if a.len() > 2 {
        eprint(&[b"uname: usage: uname [-a|-s|-n|-r|-m]\n"]);
        return 1;
    }
    let wanted: &[usize] = match a.get(1).map(|s| &s[..]) {
        Some(b"-a") => &[0, 1, 2, 3, 4],
        Some(b"-n") => &[1],
        Some(b"-r") => &[2],
        Some(b"-m") => &[4],
        Some(b"-s") | None => &[0],
        Some(other) => {
            eprint(&[b"uname: invalid option: ", other, b"\n"]);
            return 1;
        }
    };
    let mut o = Out::new(1);
    for (k, &i) in wanted.iter().enumerate() {
        if k > 0 {
            o.s(b" ");
        }
        o.s(field(i));
    }
    o.s(b"\n");
    0
}
