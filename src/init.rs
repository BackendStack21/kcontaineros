//! PID 1 for containers.
//!
//! Spawns one command, forwards every signal it receives to it, reaps
//! orphaned zombies, and exits with the command's exit status. It never
//! allocates and never polls: the main loop sleeps in `rt_sigtimedwait`.

use crate::lock;
use crate::sys;
use crate::util::{cstr, eprint, errstr, execvp, exit_code, parse_u64, DEFAULT_PATH};

const PR_SET_CHILD_SUBREAPER: usize = 36;
const TIOCGPGRP: usize = 0x540F;
const TIOCSPGRP: usize = 0x5410;
const SIGKILL: usize = 9;
const SIGPIPE: u64 = 13;
const SIGTERM: usize = 15;
const SIGCONT: usize = 18;
const SIGTSTP: i32 = 20;
const SIGTTIN: i32 = 21;
const SIGTTOU: i32 = 22;

/// Subreaper mode only: how long leftovers get to exit after SIGTERM.
const GRACE_MS: u64 = 2000;
const KILL_MS: u64 = 1000;
const GIVE_UP_MS: u64 = 5000;
const TICK_NS: u64 = 100_000_000;

pub unsafe fn run(mut cmd: *const *const u8, envp: *const *const u8) -> ! {
    if !(*cmd).is_null() && cstr(*cmd) == b"--" {
        cmd = cmd.add(1);
    }
    let default_cmd = [b"/bin/sh\0".as_ptr(), core::ptr::null()];
    if (*cmd).is_null() {
        cmd = default_cmd.as_ptr();
    }

    // Block everything: signals are consumed synchronously below, so no
    // handlers (and no async-signal-safety concerns) are needed.
    let all: u64 = !0;
    let mut original: u64 = 0;
    sys::sigsetmask(&all, Some(&mut original));
    // An ignored SIGCHLD survives exec, and with it the kernel would reap
    // the command itself and never say so: init would wait for ever.
    sys::signal(sys::SIGCHLD, 0);

    // From here on neither init nor anything it starts can gain privilege,
    // run a program from outside the image, or holds a capability.
    lock::lockdown(envp, true);
    lock::drop_capabilities();

    // Not PID 1 (`kcontaineros init cmd` in a shared PID namespace): adopt
    // orphans as a subreaper, and remember who owns the terminal so it can
    // be handed back.
    let pid1 = sys::getpid() == 1;
    let mut tty_owner: i32 = 0;
    let mut foreground = true;
    if !pid1 {
        sys::prctl(PR_SET_CHILD_SUBREAPER, 1);
        sys::ioctl(0, TIOCGPGRP, &mut tty_owner as *mut i32 as usize);
        // Started as a background job, init must not take the terminal away
        // from whoever is using it.
        foreground = tty_owner as isize == sys::getpgid();
    }

    // A warning written above to a closed pipe leaves a SIGPIPE pending for
    // init itself. It is not the command's: drop it instead of forwarding it.
    let sigpipe: u64 = 1 << (SIGPIPE - 1);
    sys::sigwait(&sigpipe, Some(0));

    let child = sys::fork();
    if child < 0 {
        eprint(&[b"kcontaineros: fork: ", errstr(child), b"\n"]);
        sys::exit(1);
    }
    if child == 0 {
        // Own process group, in the foreground of the tty if there is one, so
        // that Ctrl-C reaches the command instead of init. SIGTTOU is still
        // blocked here, which is what lets a background process do this.
        sys::setpgid(0, 0);
        let pgid = sys::getpid() as i32;
        if foreground {
            sys::ioctl(0, TIOCSPGRP, &pgid as *const i32 as usize);
        }
        sys::sigsetmask(&original, None);

        // The first PATH counts, as it does for getenv(3) in the command.
        let mut path = DEFAULT_PATH;
        let mut e = envp;
        while !(*e).is_null() {
            let var = cstr(*e);
            if var.starts_with(b"PATH=") {
                path = &var[5..];
                break;
            }
            e = e.add(1);
        }
        let file = cstr(*cmd);
        let err = execvp(file, cmd, envp, path);
        eprint(&[b"kcontaineros: ", file, b": ", errstr(err), b"\n"]);
        sys::exit(if err == sys::ENOENT || err == sys::ENOTDIR { 127 } else { 126 });
    }

    loop {
        let sig = sys::sigwait(&all, None);
        if sig <= 0 {
            continue; // interrupted: init itself was stopped and continued
        }
        if sig as usize != sys::SIGCHLD {
            sys::kill(child, sig as usize);
            continue;
        }
        loop {
            let mut status = 0;
            let pid = sys::wait4(-1, &mut status, sys::WNOHANG | sys::WUNTRACED);
            if pid <= 0 {
                break;
            }
            if pid != child {
                continue; // an adopted orphan, now reaped
            }
            if status & 0xff == 0x7f {
                // The command was stopped rather than ended. If that was
                // Ctrl-Z, nothing here could ever resume it: do it now.
                let by = (status >> 8) & 0xff;
                if by == SIGTSTP {
                    sys::kill(-child, SIGCONT);
                }
                // Stopped for touching a terminal it does not own: init was
                // started as a background job and has since been brought to
                // the foreground (`fg`). The terminal is the command's now.
                let mut owner: i32 = 0;
                if !foreground && (by == SIGTTIN || by == SIGTTOU) {
                    sys::ioctl(0, TIOCGPGRP, &mut owner as *mut i32 as usize);
                    if owner > 0 && owner as isize == sys::getpgid() {
                        let pgid = child as i32;
                        sys::ioctl(0, TIOCSPGRP, &pgid as *const i32 as usize);
                        tty_owner = owner;
                        foreground = true;
                        sys::kill(-child, SIGCONT);
                    }
                }
                continue;
            }
            if !pid1 {
                stop_leftovers(child, if foreground { tty_owner } else { 0 }, &all);
            }
            // Exiting PID 1 makes the kernel kill whatever is left.
            sys::exit(exit_code(status));
        }
    }
}

/// A subreaper's exit kills nothing, so do what the kernel does for PID 1,
/// but politely: SIGTERM what the command left behind, wait, then SIGKILL
/// until nothing is left. Also give the terminal back to whoever had it. A
/// signal sent to init in the meantime means "now": it ends the polite wait.
fn stop_leftovers(child: isize, tty_owner: i32, all: &u64) {
    if tty_owner > 0 {
        sys::ioctl(0, TIOCSPGRP, &tty_owner as *const i32 as usize);
    }
    signal_leftovers(child, SIGTERM);
    // A stopped process acts on SIGTERM only once it runs again.
    signal_leftovers(child, SIGCONT);
    let start = sys::monotonic_ms();
    let mut killing = false;
    let mut killing_since = start;
    // When SIGKILL last found something to kill.
    let mut progress = start;
    loop {
        loop {
            let mut status = 0;
            let pid = sys::wait4(-1, &mut status, sys::WNOHANG);
            if pid == sys::ECHILD {
                return;
            }
            if pid <= 0 {
                break;
            }
        }
        // By the clock, not by wake-ups: signals arriving must not stretch
        // the wait.
        let now = sys::monotonic_ms();
        if !killing && now - start >= GRACE_MS {
            killing = true;
            killing_since = now;
        }
        if killing {
            // Again on every round: what a killed process leaves behind
            // becomes init's child only once that process is gone. Not for
            // ever, though: something that forks faster than it is killed
            // must not keep init here.
            if signal_leftovers(child, SIGKILL) && now - killing_since < GIVE_UP_MS {
                progress = now;
            } else if now - progress >= KILL_MS {
                eprint(&[b"kcontaineros: warning: some processes could not be stopped\n"]);
                return;
            }
        }
        let sig = sys::sigwait(all, Some(if killing { TICK_NS / 10 } else { TICK_NS }));
        if sig > 0 && sig as usize != sys::SIGCHLD && !killing {
            killing = true;
            killing_since = sys::monotonic_ms();
            progress = killing_since;
        }
    }
}

/// Signal the command's process group and every process init has adopted;
/// returns whether an adopted one was found. Init is their subreaper, so
/// anything the command left behind has init as its parent by now, whatever
/// session or process group it moved itself to.
fn signal_leftovers(child: isize, sig: usize) -> bool {
    sys::kill(-child, sig);
    let me = sys::getpid() as u64;
    // Only a /proc that describes this PID namespace can be trusted with
    // process IDs: /proc/self has to be init.
    let mut link = [0u8; 24];
    let n = sys::readlink(b"/proc/self\0".as_ptr(), &mut link);
    if n <= 0 || parse_u64(&link[..n as usize]) != Some(me) {
        return false;
    }
    let proc_dir = sys::open(b"/proc\0".as_ptr(), sys::O_RDONLY | sys::O_DIRECTORY | sys::O_CLOEXEC, 0);
    if proc_dir < 0 {
        return false;
    }
    let mut found = false;
    let mut buf = [0u8; 2048];
    loop {
        let n = sys::getdents(proc_dir as i32, &mut buf);
        if n <= 0 {
            break;
        }
        let mut p = 0;
        while p < n as usize {
            // struct linux_dirent64 { u64 ino; i64 off; u16 reclen; u8 type; char name[]; }
            let reclen = u16::from_ne_bytes([buf[p + 16], buf[p + 17]]) as usize;
            let name = unsafe { cstr(buf.as_ptr().add(p + 19)) };
            if let Some(pid) = parse_u64(name) {
                if parent_of(name) == Some(me) && sys::kill(pid as isize, sig) == 0 {
                    found = true;
                }
            }
            p += reclen;
        }
    }
    sys::close(proc_dir as i32);
    found
}

/// The parent of process `pid` (its number as text), from /proc/PID/stat:
/// "pid (comm) state ppid ...", where comm may hold anything, so the fields
/// are counted from the last ")".
fn parent_of(pid: &[u8]) -> Option<u64> {
    let mut path = [0u8; 40];
    let parts: [&[u8]; 3] = [b"/proc/", pid, b"/stat"];
    let mut n = 0;
    for part in parts {
        if n + part.len() >= path.len() {
            return None;
        }
        path[n..n + part.len()].copy_from_slice(part);
        n += part.len();
    }
    let fd = sys::open(path.as_ptr(), sys::O_RDONLY | sys::O_CLOEXEC, 0);
    if fd < 0 {
        return None;
    }
    let mut stat = [0u8; 512];
    let len = sys::read(fd as i32, &mut stat);
    sys::close(fd as i32);
    let stat = &stat[..len.max(0) as usize];
    let close = stat.iter().rposition(|&c| c == b')')?;
    // " S 123 ..." follows: the second field after the ")".
    let mut fields = stat[close + 1..].split(|&c| c == b' ').filter(|f| !f.is_empty());
    fields.next()?;
    parse_u64(fields.next()?)
}
