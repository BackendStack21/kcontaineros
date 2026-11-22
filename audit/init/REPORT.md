# Audit of PID 1 (track: init)

kContainerOS 0.2.0, commit deffcb4. Host: macOS arm64, Docker Desktop, kernel
7.0.14-linuxkit, `pid_max` 4194304. The machine was shared with other audit
tracks while this ran (load average 6 to 17), which matters for the timing
results in section 6.

## Scope

`src/init.rs` and what it calls: `lock::lockdown` and `lock::drop_capabilities`
only as far as init's own rules go (no allocation, fixed buffers, descriptors),
`util::{execvp, eprint, exit_code, parse_u64, cstr, errstr}`, and the wrappers
in `src/sys.rs` that init uses. The lockdown's strength, the shell and the
utilities belong to other tracks.

## Method

1. Read the sources line by line and wrote down what could go wrong.
2. Tested each point against real containers: the release image, the sealed
   image and `kcos-audit`. Nothing in the repository's own test suite was used
   except `test/term.py` (a pseudo-terminal driver).
3. Where the documentation claims something about init, compared the claim
   with what the container did.

The harness is in this directory. `build.sh` builds two helper images
(`kcos-audit-init-img`: `kcos-audit` plus the static helper `kh.c` at
`/bb/kh` and fixture files in `/bb`; `kcos-audit-init-sealed`: the sealed
image plus `kh`). The compiler is the project's pinned Rust image, which has
gcc and is already cached. `run_all.sh` runs everything. Each script prints
`DIFF` with expected and actual output where a result differs, and a count.

| Script | What it does |
| --- | --- |
| `01_exit_status.sh` | exit status for every way the command can end |
| `02_signals.sh` | signal forwarding as PID 1, `docker stop` latency |
| `03_stop_signals.sh` | the command stopped by SIGTSTP, SIGTTIN, SIGTTOU, SIGSTOP; init stopped |
| `04_tty.sh` | init on a terminal, nested init in the foreground and as a background job |
| `05_reaping.sh` | zombie reaping; what a nested init does with leftovers |
| `06_flood.sh` | signals 1..16 sent to PID 1 in a loop while the command exits (measurement) |
| `07_pid_reuse.sh` | nested init and a reused PID (cycles 4194304 PIDs, about 10 minutes) |
| `08_misc.sh` | fork failure, closed or full descriptors, PATH, big argument lists, init in init, sealed image |
| `09_no_alloc.sh` | the "never allocates" and "no signal handler" rules |

## What was exercised

Counts are checks that compare complete output and exit status, as last run.

- **Exit status (346 checks, 346 as expected).** Exit codes 0..255, one
  container each. Death by every signal 1..64 with the default action (60
  checks; the four stop signals are in script 03; for 17, 18, 23 and 28, which
  do not kill, the helper's own status 99). Core dumps with `RLIMIT_CORE`
  unlimited for signals 3, 4, 6, 7, 8, 11, 24, 25, 31. Exec failures: ENOENT
  (by path, through PATH, dangling link, missing `#!` interpreter), ENOTDIR,
  EACCES (no x bit, a directory), ENOEXEC (random bytes, empty file, text
  without `#!`), ELOOP, ENAMETOOLONG (component of 300 bytes, path of 4201
  bytes, 300-byte name through PATH), empty command name, E2BIG (init started
  with an argument list at the kernel's limit and a `#!` script whose
  interpreter line needs more), `--` handling, no command, the sealed image
  without a command.
- **Signal forwarding (11 checks, 11 as expected).** All 61 signals other than
  KILL, STOP and CHLD sent one at a time (59 with `docker kill`, 32 and 33
  from inside because Docker refuses them) arrive once each, in order. SIGCHLD
  sent to init is not forwarded. 1000 queued real-time signals of number 40
  and 1000 of number 64 all arrive; 1000 of signal 10 arrive at least once. A
  signal pending before init starts is forwarded. Signals that init inherited
  as ignored are forwarded. SIGTERM immediately after `docker run -d`, ten
  times: 143 every time. `docker stop`: 0.18 s for `sleep 300` and for
  `sh -c 'sleep 300'` on the release image, exit 143. The same under
  `docker run --init`.
- **Stop signals (8 checks, 6 as expected, 2 are finding 1).**
- **Terminal (4 checks as expected, 6 sessions printed and read).** Ctrl-Z on
  a plain command, Ctrl-Z/Ctrl-C/Ctrl-\ on a command that catches them,
  escape sequences and a 1200-byte name in init's own error message,
  interactive shell, nested init in the foreground (exit, Ctrl-C, Ctrl-Z),
  nested init as a background job that reads the terminal and is then brought
  to the foreground, the same writing with `tostop` set.
- **Reaping and leftovers (16 checks, 15 as expected, 1 is finding 4; three
  more results printed).** 5000 short-lived orphans as PID 1, 250 alive at
  once, 20000 under `docker run --init`, all with `--pids-limit 300 --memory
  256m`. PID 1 exits at once with stubborn, stopped and forking leftovers.
  Nested: leftovers that die of SIGTERM, are stopped, ignore SIGTERM, sit in
  another session, are named `x) S 1 1 1 (`, have children of their own, fork
  and change session in a loop; a signal to init during the 2 s; a process
  that is not a descendant; a fork bomb held by the pids limit; a `/proc` of
  another PID namespace; another container's PID namespace.
- **Signal flood (10 timed runs, no assertion).**
- **PID reuse (2 checks, 1 is finding 3).**
- **Unusual starts (34 checks, 34 as expected).** `--pids-limit 1`; stdin,
  stdout and stderr closed, alone and together, with and without warnings to
  print; stderr on `/dev/full`; stderr a closed pipe; PATH missing, empty,
  relative, with a file, a missing directory, a 5000-byte entry, an
  unsearchable directory, a non-executable file before the real one, a text
  file without `#!`; a 100000-byte argument, 5000 arguments, an argument list
  at the kernel's limit; init as the command of init, three deep, with
  signals and `docker stop`; `kcontaineros init`; the sealed image (status,
  signal death, missing command, signals, 3000 orphans).
- **No allocation, no handler (5 checks, 5 as expected).**

## Results

### Findings

1. **A forwarded SIGTTIN or SIGTTOU stops the command for good, and
   `docker stop` then has to wait for SIGKILL** (low). `docker kill -s TTIN`
   (or TTOU) is forwarded to the command, whose default action is to stop.
   Init resumes a command stopped by SIGTSTP and does nothing for the other
   stop signals. After that `docker stop -t 5` took 5 s and ended with 137
   instead of 0 s and 143, because the forwarded SIGTERM stays pending in a
   stopped process. With the command as PID 1 (no init) and with
   `docker run --init` the same signal leaves the command running. A command
   stopped by SIGSTOP from inside the container ends the same way.
2. **Signals 1..16 sent to PID 1 in a loop delay the moment init notices that
   the command has ended** (low). Init takes one signal per
   `rt_sigtimedwait`; the kernel returns the lowest pending number, and
   SIGCHLD is 17. With 90 processes in the container sending signals 1..16 to
   PID 1, the container outlived its command by up to 9.6 s (five runs: 10.9,
   4.4, 1.5, 2.4, 5.4 s to the end of the container; three control runs with
   the same 90 processes signalling a PID that does not exist: 1.4, 1.8,
   1.3 s). With 4 and 40 flooders no delay was measurable. It never became
   permanent here. Zombies are not reaped during the delay either.
3. **A nested init signals a process group it no longer owns** (low). When
   init is not PID 1, `stop_leftovers` calls `kill(-child, sig)` for SIGTERM,
   SIGCONT and then SIGKILL every 10 ms, after `child` has been reaped. If
   every leftover has left the command's process group, that number is free.
   Reproduced: after cycling the PID counter (4193999 forks), a process
   started by the outer shell, not a descendant of init, got PID 401 (the
   command's), called `setpgid(0, 0)` and was killed by init's SIGKILL one
   second later (status 137). In the control without PID reuse it lived.
   Init's signal carries no more permission than the leftover has, so this is
   a wrong-process bug and not a privilege gain.
4. **A nested init treats every child it has as a leftover of the command**
   (low). Processes that were already children of the program that exec'ed
   init (`sh -c 'daemon & exec /sbin/init -- cmd'`) are signalled with SIGTERM
   and, after 2 s, SIGKILL when the command ends. The README says it stops
   "what the command left behind".
5. **A nested init gives up on leftovers that fork faster than they are
   killed** (info). 300 signal-ignoring processes each in its own session
   (held by `--pids-limit 300`): in two of three runs init printed
   `kcontaineros: warning: some processes could not be stopped` after about
   8.6 s and exited with the command's status, leaving 295 to 299 processes
   running; in one run it killed them all in about 4 s. The code says so in a
   comment; the README row ("stops what the command left behind ... SIGTERM,
   then SIGKILL after 2 s") does not mention that it can give up. The same
   warning, after 2 s, when `/proc` belongs to another PID namespace: a
   leftover outside the command's process group then survives.

### What held

See the `held` list of the structured result; in short: status mapping,
forwarding, reaping, terminal handling, timing of the nested shutdown
(0 s / 2 s as documented), fail-safe behaviour with a foreign `/proc`,
hostile process names, the fixed buffers, fork failure, closed descriptors,
and the no-allocation and no-handler rules.

Notes that are not findings:

- The sealed binary (19160 bytes) contains no instruction that loads syscall
  number 222 (mmap), 215 (munmap) or 214 (brk) into any register, so it cannot
  allocate at all; execve (221) and rt_sigtimedwait (137) are found once each
  by the same search. In the full binary the allocator exists (5 loads of
  222), so there the rule was checked by reading (`init.rs` and `lock.rs`
  import only `cstr`, `eprint`, `errstr`, `execvp`, `exit_code`, `parse_u64`
  from `util`, none of which allocates) and by looking at a running init: its
  only unnamed anonymous mapping is one 4096-byte page (`.bss`), as PID 1
  after printing warnings, forwarding signals and reaping 500 orphans, and
  nested during `stop_leftovers`. The control, `sleep` from the same binary,
  has the allocator's 262144-byte chunk. `SigCgt` and `SigIgn` of init are 0.
- Under `docker run --init`, SIGTTIN and SIGTTOU never reach this init:
  Docker's own init keeps them.
- A text file without `#!` found through PATH ends init's search with
  "exec format error", status 126. Init has no shell to hand it to.
- PID 1's shutdown does not depend on `/proc`; only the nested mode reads it.
- The child process PID seen by the command was 6 in some runs and 7 in
  others; nothing depends on it.

## Not tested, and why

- **`/proc` absent or replaced by something else.** runc refuses to mount
  anything but proc on `/proc`. Covered instead: a `/proc` of another PID
  namespace (`unshare -p`).
- **`argc == 0`.** Linux since 5.18 turns an empty argument vector into
  `[""]`, so the `argc == 0` branches in `main.rs` cannot be reached on this
  kernel.
- **Two `PATH` entries in the environment** ("the first PATH counts"): read
  in the source only.
- **`--pid=host`.** Left out on purpose: a mistake there would reach other
  auditors' processes. `--pid=container:X` was used instead.
- **Kernels without Landlock, user-namespace remapping, Kubernetes,
  cgroup freezer (`docker pause`)**: not available or not in this track.
- **A permanent starvation of SIGCHLD** (finding 2): the ordering allows it
  in principle; on this loaded 10-CPU VM the longest delay was 9.6 s.
- **Signals during the few instructions between `fork` and `execve`**: not
  controllable from outside; the ten immediate `docker kill` runs and the
  pending-signal case go through the same code but cannot say which
  instruction they hit.
- **Dynamic tracing of system calls** (strace): not used, because of the rule
  against leaving traced processes behind; the memory-map check stands in
  for it.
