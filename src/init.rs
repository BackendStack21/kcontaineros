//! PID 1 for containers.
//!
//! Spawns one command, forwards every signal it receives to it, reaps
//! orphaned zombies, and exits with the command's exit status. It never
//! allocates and never polls: the main loop sleeps in `rt_sigtimedwait`.

use crate::lock;
use crate::sys;
use crate::util::{cstr, eprint, errstr, execvp, exit_code, DEFAULT_PATH};

const PR_SET_CHILD_SUBREAPER: usize = 36;
const TIOCGPGRP: usize = 0x540F;
const TIOCSPGRP: usize = 0x5410;
const SIGKILL: usize = 9;
const SIGTERM: usize = 15;
const SIGCONT: usize = 18;
const SIGTSTP: i32 = 20;

/// Subreaper mode only: how long leftovers get to exit after SIGTERM.
const GRACE_MS: u64 = 2000;
const KILL_MS: u64 = 1000;
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

    // From here on neither init nor anything it starts can gain privilege,
    // run a program from outside the image, or holds a capability.
    lock::lockdown(envp, true);
    lock::drop_capabilities();

    // Not PID 1 (`kcontaineros init cmd` in a shared PID namespace): adopt
    // orphans as a subreaper, and remember who owns the terminal so it can
    // be handed back.
    let pid1 = sys::getpid() == 1;
    let mut tty_owner: i32 = 0;
    if !pid1 {
        sys::prctl(PR_SET_CHILD_SUBREAPER, 1);
        sys::ioctl(0, TIOCGPGRP, &mut tty_owner as *mut i32 as usize);
    }

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
        sys::ioctl(0, TIOCSPGRP, &pgid as *const i32 as usize);
        sys::sigsetmask(&original, None);

        let mut path = DEFAULT_PATH;
        let mut e = envp;
        while !(*e).is_null() {
            let var = cstr(*e);
            if var.starts_with(b"PATH=") {
                path = &var[5..];
            }
            e = e.add(1);
        }
        let file = cstr(*cmd);
        let err = execvp(file, cmd, envp, path);
        eprint(&[b"kcontaineros: ", file, b": ", errstr(err), b"\n"]);
        sys::exit(if err == sys::ENOENT { 127 } else { 126 });
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
                if (status >> 8) & 0xff == SIGTSTP {
                    sys::kill(-child, SIGCONT);
                }
                continue;
            }
            if !pid1 {
                stop_leftovers(child, tty_owner, &all);
            }
            // Exiting PID 1 makes the kernel kill whatever is left.
            sys::exit(exit_code(status));
        }
    }
}

/// A subreaper's exit kills nothing, so do what the kernel does for PID 1,
/// but politely: SIGTERM the command's process group, wait, then SIGKILL.
/// Also give the terminal back to whoever had it.
fn stop_leftovers(child: isize, tty_owner: i32, all: &u64) {
    if tty_owner > 0 {
        sys::ioctl(0, TIOCSPGRP, &tty_owner as *const i32 as usize);
    }
    sys::kill(-child, SIGTERM);
    let start = sys::monotonic_ms();
    let mut killed = false;
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
        // By the clock, not by wake-ups: signals arriving must not shorten
        // or stretch the wait.
        let waited = sys::monotonic_ms() - start;
        if waited >= GRACE_MS + KILL_MS {
            return;
        }
        if waited >= GRACE_MS && !killed {
            sys::kill(-child, SIGKILL);
            killed = true;
        }
        sys::sigwait(all, Some(TICK_NS));
    }
}
