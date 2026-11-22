# Track: init

What the auditor of this track reported, unedited apart from layout, and what the
independent reviewer made of each finding. The state of the tree is that of 0.2.0
(commit `deffcb4`); what was done about each finding is in [../README.md](../README.md).

## What was exercised

Audited PID 1 (src/init.rs and what it calls) of kContainerOS 0.2.0 at deffcb4 by reading the source line by line and testing against real containers (release image, sealed image, kcos-audit plus a static C helper). No escape, privilege gain, crash or hang of PID 1 was found; five findings, four low and one info, all about availability or wrong-process signalling.

Exercised, as last run: 01 exit status 346 checks (256 exit codes, 60 signal deaths, 9 core dumps, 21 exec-failure/argv cases incl. ENOENT/ENOTDIR/EACCES/ENOEXEC/ELOOP/ENAMETOOLONG/E2BIG), all as expected; 02 signal forwarding 11 checks (61 signals individually, 3000 queued signals, pending-before-start, inherited-ignored, 10 immediate SIGTERMs, docker stop latency, --init), all as expected; 03 stop signals 8 checks, 2 differ (finding 1); 04 terminal 4 checks as expected plus 6 printed sessions; 05 reaping/leftovers 16 checks, 1 differs (finding 4), plus 3 printed measurements (finding 5); 06 signal flood 10 timed runs (finding 2); 07 PID reuse 2 checks, 1 differs (finding 3); 08 unusual starts 34 checks, all as expected; 09 no-allocation/no-handler 5 checks, all as expected.

The host was shared with other audit tracks (load average 6 to 17), so the timing numbers in findings 2 and 5 vary between runs. The helper images kcos-audit-init-img and kcos-audit-init-sealed were removed at the end; audit/init/build.sh rebuilds them (using the project's pinned Rust image as the C compiler, because `apk add gcc` failed with the Docker disk 98% full). Nothing outside audit/init/ was changed. Full write-up: audit/init/REPORT.md.

## What held

- Exit status pass-through: exit codes 0..255 each returned unchanged (256 containers, init as PID 1).
- Death by signal gives 128+N for every signal 1..64 with a fatal default action (56 signals), and with a core dump for signals 3, 4, 6, 7, 8, 11, 24, 25, 31.
- Exec failures map as coded: ENOENT and ENOTDIR give 127; EACCES, ENOEXEC, ELOOP, ENAMETOOLONG (300-byte component, 4201-byte path) and E2BIG give 126, each with the right message and no crash or buffer overrun.
- Forwarding as PID 1: all 61 signals other than KILL, STOP and CHLD arrive at the command once each and in order, including real-time 32..64; 1000 queued signals 40 and 1000 queued signals 64 all arrive.
- A signal pending before init starts is forwarded; signals init inherited as ignored are still forwarded; SIGTERM immediately after `docker run -d` gave 143 ten times out of ten.
- docker stop latency: 0.12 to 0.24 s with exit 143 for `sleep 300` and for shell-form `sh -c 'sleep 300'` on the release image, in line with the README's 0.11 s.
- Ctrl-Z does not leave the command stopped (init sends SIGCONT); Ctrl-C, Ctrl-Z and Ctrl-\ reach a command that catches them.
- Terminal handling when nested: the terminal is handed back after exit and after Ctrl-C; a nested init started as a background job leaves the terminal alone and takes it over correctly after `fg` (reading, and writing with tostop).
- Init's own error message on a terminal replaces escape sequences with `?`, and a 1200-byte name is printed whole through the 512-byte buffer.
- Zombie reaping: 5000 short-lived orphans and 250 simultaneous ones as PID 1, 20000 under `docker run --init`, 3000 on the sealed image: zero zombies left.
- PID 1 exits at once with the command's status whatever is left behind (stubborn, stopped, session-changing, forking leftovers).
- Nested shutdown timing matches the README: 0 s when leftovers die of SIGTERM (including stopped ones and ones in another session), 2 s then SIGKILL when they ignore it, immediate SIGKILL when init is signalled during the wait; `docker stop` under `--init` with a stubborn leftover took 2.2 s.
- Hostile process names: leftovers with comm `x) S 1 1 1 (` (via PR_SET_NAME and via the file name) are found and killed; parent_of's use of the last `)` holds.
- With a /proc that belongs to another PID namespace, a nested init does not signal by PID at all (the /proc/self check works) and prints a warning.
- In another container's PID namespace (`--pid=container:X`) the leftover was killed and the other container was untouched.
- A process that is not a child of the nested init was left alone (apart from the PID-reuse case in finding 3).
- Fork failure (`--pids-limit 1`): message `kcontaineros: fork: resource temporarily unavailable`, status 1, no hang.
- stdin/stdout/stderr closed (alone and together), stderr on /dev/full, stderr a closed pipe with a warning to print: correct status, nothing written to a wrong descriptor, no SIGPIPE forwarded to the command.
- PATH handling: missing (default used), empty and relative (current directory), entries that are a file, missing, 5000 bytes long or unsearchable are skipped; a non-executable file earlier in PATH does not hide the program.
- Large arguments: one 100000-byte argument, 5000 arguments, and an argument list at the kernel's limit are passed on intact.
- Init as the command of init (three deep) and `kcontaineros init` as entry point: status, signals and sub-second `docker stop` all work.
- Never allocates: the sealed binary (19160 bytes) has no instruction loading syscall 222, 215 or 214; a running init (PID 1 after warnings, signals and 500 reaped orphans, and nested during stop_leftovers) has only one 4096-byte anonymous page, while `sleep` from the same binary has the allocator's 262144-byte chunk.
- No signal handler: SigCgt and SigIgn of init are 0 in both modes; init.rs and lock.rs import only non-allocating helpers from util.rs.
- Fixed buffers read in source and exercised at their limits without fault: execvp's 4096-byte path buffer, parent_of's 40-byte path and 512-byte stat buffer, eprint's 512-byte terminal buffer.
- parent_of/kill by PID is not racy: a child of init stays a zombie until init itself reaps it, so its PID cannot be reused between the read of /proc/PID/stat and the kill.

## Not tested

- /proc absent or replaced by another filesystem: runc refuses to mount anything but proc on /proc. A /proc of another PID namespace (unshare -p) was tested instead.
- argc == 0: Linux since 5.18 turns an empty argument vector into [""], so those branches in main.rs cannot be reached on this kernel.
- Two PATH entries in the environment ("the first PATH counts"): read in the source only.
- --pid=host: left out on purpose, because a mistake would reach other auditors' processes; --pid=container:X was used instead.
- Permanent starvation of SIGCHLD (INIT-2): the dequeue order allows it in principle, but the longest delay achieved on this loaded VM was 9.6 s.
- Signals landing exactly between fork and execve in the child: not controllable from outside; ten immediate `docker kill` runs and the pending-before-start case go through that code without showing which instruction they hit.
- System call tracing of init (strace): not used because of the rule against leaving traced processes behind; the memory-map and disassembly checks stand in for it. For the full binary the no-allocation rule therefore rests on source reading plus the memory map of running inits, not on a call-graph proof.
- Kernels without Landlock, user-namespace remapping, Kubernetes, and `docker pause` (cgroup freezer).
- run_all.sh was not run end to end in one go; each script was run on its own (several more than once) and the counts are from the last run of each.

## Findings

### INIT-1 — A forwarded SIGTTIN or SIGTTOU stops the command for good; docker stop then needs SIGKILL

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/init.rs:107-141 (main loop: forwards every signal; only a stop by SIGTSTP is undone)

Init forwards SIGTTIN and SIGTTOU like any other signal. Their default action stops the command. Init resumes a command stopped by SIGTSTP, but for SIGTTIN/SIGTTOU it only acts when it is a nested background job, and never for SIGSTOP. As PID 1 the command stays stopped. The SIGTERM that `docker stop` sends is forwarded but stays pending in the stopped process, so the container is only ended by Docker's SIGKILL after the full timeout, with 137 instead of the command's own status. Without init, and with Docker's own `--init`, the same `docker kill -s TTIN` leaves the command running. A command stopped by SIGSTOP from inside the container ends the same way (5 s, 137). The README says `docker stop` reaches the command at once and that Ctrl-Z has no effect because nothing could resume the command; the same reasoning applies to these signals but is not implemented.

Reproduction:

```
audit/init/build.sh && audit/init/03_stop_signals.sh

# by hand:
docker run -d --name kcos-audit-init-x --platform linux/arm64 kcos-audit /bb/busybox sleep 300
docker kill -s TTIN kcos-audit-init-x
docker exec kcos-audit-init-x /bb/busybox sh -c 'cat /proc/[0-9]*/stat' | grep sleep   # third field
time docker stop -t 5 kcos-audit-init-x; docker wait kcos-audit-init-x; docker rm kcos-audit-init-x
# control: docker run -d --entrypoint /bb/sleep kcos-audit 300, same docker kill
```

Expected: The command keeps running (state S), `docker stop -t 5` returns in about 0 s and the container exits with 143, as it does after `docker kill -s TSTP`.

Observed: `docker kill -s 21: command state T, then docker stop -t 5 took 5 s, exit 137`; identical for signal 22. Controls: `control (--entrypoint /bb/sleep): after docker kill -s 21 the sleep is in state S`, and the same with `--init`.

Reviewer: README line 215 says docker stop reaches the command at once and line 447 only covers Ctrl-Z; nothing documents this. src/init.rs:125 resumes only after SIGTSTP. Needs a stop signal sent to the container from outside or by a same-user process inside; the result is a slow docker stop with 137, so low.

### INIT-2 — Signals 1..16 sent to PID 1 in a loop delay init noticing that the command ended

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/init.rs:107-115 (one signal per rt_sigtimedwait, SIGCHLD handled only when it is the one returned)

The main loop takes one signal per `rt_sigtimedwait` and forwards it. The kernel returns the lowest pending signal number first and SIGCHLD is 17, so while any of the signals 1..16 is pending at each call, the SIGCHLD of the exited command is not taken: the container keeps running with a zombie command, and no orphan is reaped. Any process in the container can send these signals to PID 1. Measured with 90 flooder processes: the container outlived its command by up to 9.6 s. With 4 and 40 flooders no delay was measurable, and the starvation never became permanent on this (heavily loaded, 10-CPU) VM; four flooders sent about 2.6 million signals per second while init forwarded about 240 thousand. A hostile process of the same user can already stop the command by other means, so the impact is limited to delaying container exit and reaping.

Reproduction:

```
audit/init/build.sh && audit/init/06_flood.sh

# one run by hand (the command ignores signals 1..16, starts 90 flooders for 40 s, exits 7 after 1 s):
S="1 2 3 4 5 6 7 8 10 11 12 13 14 15 16"
time docker run --rm --platform linux/arm64 --pids-limit 120 --memory 128m kcos-audit-init-img /bb/kh ignoring $S -- /bb/busybox sh -c "/bb/kh flood 1 90 40 $S; /bb/kh sleepms 1000; exit 7"
# control: replace `flood 1` by `flood 999999` (a PID that does not exist)
```

Expected: The container ends with status 7 about one second after start, as in the control with the same CPU load (measured 1.4, 1.8, 1.3 s).

Observed: `target 1, 90 flooders: container ended with 7 after 10.9 s`, then 4.4 s, 1.5 s, 2.4 s, 5.4 s in further runs (earlier runs: 8.5, 4.5, 2.0, 1.5, 3.3 s). Control runs: 1.4, 1.8, 1.3 s.

Reviewer: Stronger than reported: here the starvation was total and deterministic with 4 or more flooders, the container lived exactly as long as the flood in every run (the auditor measured only a few seconds of delay and nothing with 4 or 40). Kept at low because sender and init are the same uid, which can already stop the command with SIGSTOP (INIT-1), and nothing is gained past the lockdown; it is a self-inflicted availability issue (container outlives its command, needs docker stop's SIGKILL). Not documented in README.

### INIT-3 — A nested init keeps signalling the command's process group after reaping it; a reused PID gets its SIGKILL

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/init.rs:214-216 (signal_leftovers: sys::kill(-child, sig)), called from stop_leftovers at 157-159 and 190

When init is not PID 1, `stop_leftovers` runs after the command has been reaped. `signal_leftovers` starts with `kill(-child, sig)`: SIGTERM and SIGCONT once, then SIGKILL every 10 ms for as long as a leftover is alive. If no leftover is in the command's process group any more, that group number is free, and a process that is given the command's old PID and becomes a group leader is signalled although it has nothing to do with init. Reproduced end to end: the outer PID 1 shell starts init, whose command leaves one stubborn orphan in another session; the PID counter is cycled (4193999 forks) so that the next PID is the command's; the command exits; one second later the outer shell starts a process of its own that calls `setpgid(0,0)`. It got PID 401, the command's, and was killed by init one second after that. In the control without PID reuse it lived. Init's signal has no more permission than the leftover itself has (same uid, no capabilities), so this is a wrong-process bug, not a privilege gain. It needs a shared PID namespace (`--init`, `--pid=container:`, `--pid=host`, or a parent that is not init) and a wrapped PID counter, which a leftover can prepare before the command exits. The per-PID kills are not affected: an adopted child stays a zombie until init reaps it.

Reproduction:

```
audit/init/build.sh && audit/init/07_pid_reuse.sh     # about 10 minutes; WRAP=0 runs only the control
```

Expected: `leader: survived` and `bystander ended with status 0`: a process that is not a descendant of init is never signalled by it.

Observed: ``` / init is 400, its command is 401 / wrap: 4193999 forks, next pid is 400 / leader: pid 401 pgid 401 ppid 1 / Killed / bystander ended with status 137 / init ended with status 5 / ``` / Control (no PID reuse): `leader: pid 404 pgid 404 ppid 1`, `leader: survived`, `bystander ended with status 0`.

Reviewer: src/init.rs:213 sends kill(-child, sig) on every round after the command was reaped. Only in nested mode, needs a wrapped PID counter and a leftover outside the group; the victim is a process the same user could signal anyway, so no privilege gain. Low.

### INIT-4 — A nested init kills children it inherited from the program that exec'ed it

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/init.rs:210-246 (signal_leftovers: every process whose parent is init)

In nested mode `signal_leftovers` signals every process in /proc whose parent is init. That includes processes that were children of the program which exec'ed init and were never started by the command, for example a helper started by a wrapper script before `exec /sbin/init -- cmd`. When the command ends they get SIGTERM and, after 2 s, SIGKILL. The README describes this mode as stopping "what the command left behind". As PID 1 the question does not arise, because the kernel kills everything when PID 1 exits.

Reproduction:

```
audit/init/build.sh
docker run --rm --platform linux/arm64 --entrypoint /bb/busybox kcos-audit-init-img sh -c '/bb/busybox sh -c "/bb/kh stubborn 30 & /bb/busybox sleep 30 & exec /sbin/init -- /bb/busybox true"; echo "init status $?"; /bb/busybox ps -o pid,ppid,comm'
# also the check "nested: children init inherited ..." in audit/init/05_reaping.sh
```

Expected: The two processes started before init (`kh stubborn 30`, `sleep 30`) are still listed after init has returned: the command (`true`) left nothing behind.

Observed: ``` / init status 0 / PID   PPID  COMMAND /     1     0 busybox / ``` / Both were killed; init took 2 s to return (the SIGTERM-ignoring one was SIGKILLed).

Reviewer: README line 459 says a nested init "stops what the command left behind"; these processes were started before init existed. Unusual setup (a wrapper with background children that execs init), and partly a matter of wording. Low.

### INIT-5 — A nested init can give up and leave leftovers running; the README does not say so

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: src/init.rs:186-196 (GIVE_UP_MS / KILL_MS), README.md "Supported features" row "init | Running nested, not as PID 1"

The README says a nested init "stops what the command left behind, in whatever session or process group (SIGTERM, then SIGKILL after 2 s ...)". Two cases where it does not, both announced only by a warning line on stderr while init still exits with the command's status: (a) leftovers that fork faster than they are killed, each in its own session: with 300 signal-ignoring processes held by `--pids-limit 300`, init gave up after about 8.6 s in two of three runs and left 295 and 299 processes running (in the third run it killed them all in about 4 s); (b) when /proc does not describe init's PID namespace, a leftover outside the command's process group survives and the warning comes after 2 s. Both behaviours are deliberate in the code and fail safe; the documentation states the guarantee without the limit.

Reproduction:

```
audit/init/build.sh && audit/init/05_reaping.sh     # see the lines "nested, fork bomb as leftover" and "nested in a new PID namespace with the outer /proc"

# (a) by hand:
docker run --rm --platform linux/arm64 --pids-limit 300 --memory 256m --cpus 2 --entrypoint /bb/busybox kcos-audit-init-img sh -c '/sbin/init -- /bb/busybox sh -c "/bb/kh bomb 14 & /bb/kh sleepms 300; exit 5"; echo "status $?"; n=0; for p in /proc/[0-9]*; do n=$((n+1)); done; echo "$n processes left"'
```

Expected: Per the README row: after SIGTERM and, 2 s later, SIGKILL, nothing the command left behind is running.

Observed: (a) `kcontaineros: warning: some processes could not be stopped`, `status 5`, `299 processes left`, after 8.6 s in all (another run: 295 left after 8.8 s; a third: all killed, `1 processes left` after 4.1 s, no warning). (b) `kcontaineros: warning: some processes could not be stopped status 5 after 2000 ms`, with the session-changing leftover still running.

Reviewer: Both limits are deliberate (GIVE_UP_MS, the /proc/self check at init.rs:217-221), fail safe and are announced on stderr, but README line 459 states the guarantee without them. In my runs the fork-bomb case gave up 3 times out of 3. Documentation gap on a non-security feature: info.

