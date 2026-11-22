# Track: escape-user

What the auditor of this track reported, unedited apart from layout, and what the
independent reviewer made of each finding. The state of the tree is that of 0.2.0
(commit `deffcb4`); what was done about each finding is in [../README.md](../README.md).

## What was exercised

Audited kContainerOS 0.2.0 as a hostile default-user (nobody) workload under init across 17 Docker configurations. Exercised ~700 run-time-code-execution attempts (44 routes × configs; 0 started a written program under init, controls started 13-24 each), 9 writable-directory sweeps, 10 exit-status checks, 12 seccomp probes, and ~50 terminal-message cases, each with a no-init control. The run-or-write rule, capability drop, seccomp filter, PID-1 opacity, device rules, exit-status pass-through, leftover cleanup (PID 1 and --pid host, including PID-churning and SIGTERM-ignoring chains), docker stop, docker-exec/--pid-host isolation, and environment-variable hardening all held exactly as documented. Three findings: two medium (documented claims false in named cases), one low. Harness at audit/escape-user/{build.sh,01-05,lib.sh,inside/,helper/}; report at audit/escape-user/REPORT.md.

## What held

- Run-or-write rule: 0 of 44 execution routes started a run-time-written program under init across 17 configs (plain, --read-only, named volume, --tmpfs exec, /dev/shm +-exec, --ipc/--pid/--network host, -p, --device, --privileged --cap-add ALL, root --privileged, --init, seccomp=unconfined apparmor=unconfined, alt uid, third-party image, sealed agent recipe); controls started 13-24
- Execution routes blocked include execveat(AT_EMPTY_PATH), execve(/proc/self/fd/N), O_TMPFILE+fchmod, memfd_create, SysV-shm map_files, /proc/self/exe re-exec with crafted argv[0], nested init, symlink/shebang/no-shebang/relative/proc-root/dev-fd, LD_PRELOAD/LD_LIBRARY_PATH/LD_AUDIT, PATH lookup
- Documented interpreter and in-process code routes (sh FILE, sh < FILE, mmap(PROT_EXEC), read-into-anonymous-memory+mprotect) run exactly as the README says
- Writable directory set under init is precisely documented: /tmp /var/tmp /dev/shm; --ipc none removes /dev/shm; --read-only leaves only the tmpfs; sealed agent recipe leaves only /work
- Program directories (/bin /sbin /usr, KCOS_EXEC) and a volume mounted inside /usr are immutable: create/append/unlink/mkdir/rename/symlink/hardlink all refused under init, all succeed in control
- Program-directory file CONTENTS are immutable even for the owning user (create/append/rm/mkdir refused)
- /proc and /sys not writable for root under init (sysrq, hostname, sysrq-trigger append-and-close refused)
- PID 1 opacity: environ, mem, fd, maps, exe, root, cwd, auxv, io of PID 1 all refused to default user; control (PID 1 is the shell) exposes them
- Device rule: unnamed --device /dev/fuse not openable, KCOS_DEV-named one openable (control: openable without a name); device mapped outside /dev is an ordinary openable file (documented limit)
- Seccomp filter (root, --privileged, seccomp=unconfined): memfd_create, memfd_secret, ptrace, process_vm_readv, io_uring_setup, bpf, userfaultfd, vsock, CLONE_NEWUSER, unshare all refused; clone3 and syscall past NEWEST_KNOWN give ENOSYS; socket(AF_INET) and threading clone allowed
- NoNewPrivs:1, Seccomp:2, CapEff:0 in all configs; CapBnd:0 as root (CAP_SETPCAP), non-empty but inert as nobody (exactly the documented capability limit)
- Exit status: command's own status passed through (0/7/255; 137/143/139 on signal; 127/126 not-found/not-exec; command's status not an orphan's or earlier child's)
- init survives SIGKILL/SIGSTOP to PID 1, 5000 forwarded signals to an ignoring command, and a 2000-orphan SIGCHLD storm
- Leftover cleanup: setsid/double-fork/own-group/stopped/SIGTERM-ignoring leftovers all removed as PID 1 (kernel) and under --pid host (init's SIGTERM->SIGKILL sweep), including PID-churning chains that change PID every millisecond; no survivors on the host process list
- docker stop reaches the command at once (143); a SIGTERM-ignoring command is killed at the timeout (137); nothing survives
- Environment influence: ENV, BASH_ENV, IFS, PS1, PS4, PWD, OLDPWD, SHELLOPTS, CDPATH do not steer the shell; IFS cannot be changed; PATH/LD_* at a written file inert; KCOS_EXEC cannot name /dev, /proc or /sys
- docker exec session and another container's process (--pid host) of the same user: workload cannot open their memory/root/environ/fd/cwd/maps nor exec through /proc/PID/root; TIOCSTI into a session terminal refused by the kernel
- docker exec shell has no_new_privs + filter, keeps capabilities, is outside Landlock (as documented)
- No-Landlock fallback (simulated by erroring landlock_* via seccomp): init warns, run-or-write off, filter still on; a low nofile soft limit cannot create a silent fallback because the runtime refuses to start the container first
- Terminal sanitization WITH -t: init, shell and every utility replace non-printable bytes with ? in messages derived from argv/filenames/env (16+ cases)
- Binary does not crash on unusual argv (empty argv, empty argv[0], bare 'init'); sealed binary called as 'sh' is still init

## Not tested

- A genuinely Landlock-less or pre-5.19 kernel (only simulated the three landlock_* syscalls failing via a custom seccomp profile)
- Native-Linux (non-Docker-Desktop) bind-mount behaviour, which the README says differs from Docker Desktop shares
- User-namespace remapping, Kubernetes, and rootless Docker (untested per README; not configured on this host)
- TIOCSTI on a kernel with legacy_tiocsti enabled (disabled globally on this LinuxKit kernel, so the refusal is the kernel's not init's)
- Whether F2's escape bytes drive a specific terminal emulator to a concrete action (confirmed only that raw bytes reach a pty)
- Exhaustive fuzzing of the shell parser/expansion for correct-or-loud violations beyond the targeted cases run

## Findings

### F1 — KCOS_EXEC entries ignored as 'not a plain absolute path' leave their top-level directory writable, contradicting the README

- Severity: auditor **medium**, reviewer **medium**
- Reviewer's verdict: reproduced
- Where: src/lock.rs confine_files / absolute_dirs; README.md Use section

The README states: 'a trailing slash, . or .. components and anything reached through a symbolic link are ignored, with a warning. The top-level directory of an ignored entry is not writable all the same.' For exactly that class of entry (trailing slash, ., .., //) the top-level directory stays writable. Root cause: absolute_dirs() filters trailing-slash/./.. entries out before the per-top-level holds_programs test is computed from absolute_dirs(extra), so the directory is never marked program-holding and receives write access in the root sweep. Entries that instead fail later at allow() (e.g. a non-directory path like /tmp/sub) still appear in absolute_dirs and so still protect their top-level directory, producing inconsistent behaviour. No code-execution escape: the directory becomes writable but is not an exec directory, so nothing written there can be started. Impact is documentation / defense-in-depth: an operator who typos KCOS_EXEC=/data/bin/ believes /data stays non-writable when it does not.

Reproduction:

```
docker run --rm --platform linux/arm64 -u 65534:65534 -e KCOS_EXEC=/tmp/ kcos-audit-escape-user-img /bin/sh -c 'echo x > /tmp/f; echo "write-to-/tmp=$?"'  # also /tmp/. , /tmp/../tmp , //tmp . Compare valid /tmp or /tmp/sub which give write-to-/tmp=1. Harness: audit/escape-user/02-write-read.sh (KCOS_EXEC section).
```

Expected: write-to-/tmp=1 (refused), per README 'The top-level directory of an ignored entry is not writable all the same.'

Observed: kcontaineros: warning: KCOS_EXEC: /tmp/ is not a plain absolute path: ignored\nwrite-to-/tmp=0  (the write succeeds; /tmp stays writable)

Reviewer: The README sentence is false for exactly the entry class it lists first (trailing slash, ., .., empty component); it holds only for entries rejected later in allow() (not a directory / symlink). Run-or-write itself is intact: the directory stays writable but not executable, so this is a wrong documentation claim plus inconsistent behaviour, not an escape. test/suite.sh has no check on the top-level directory of a 'not a plain absolute path' entry. Medium as misleading security documentation.

### F2 — Terminal-escape sanitization is bypassed when the container's output is not a tty (default docker run without -t); init/shell/utility messages reach the operator's terminal raw

- Severity: auditor **medium**, reviewer **info**
- Reviewer's verdict: reproduced, already documented
- Where: src/util.rs eprint and Out::safe (isatty(fd) gate); AGENTS.md 'Nothing untrusted reaches a terminal raw'; README.md Security/tools sections

Message sanitization that replaces non-printable bytes with ? is gated on isatty(fd) of the container process's own descriptor. Run without -t, that descriptor is a pipe, so no sanitization is applied; Docker then copies the pipe to the operator's real terminal, so attacker-controlled bytes (from Dockerfile ENV KCOS_EXEC/KCOS_DEV, argv, or file names) reach the operator's terminal raw. Confirmed for init warnings, shell errors and utility errors. With -t the identical cases are sanitized. Most realistic delivery: a malicious base image sets ENV KCOS_EXEC=<escape>; init prints the ignored-entry warning on every run, so any operator doing 'docker run that-image' (no -t) at a terminal receives the escape sequence. Impact is terminal injection / operator deception (cursor, colour, BEL, and on some emulators clipboard/command insertion); not a container escape or privilege gain. The README's precise wording ('when the output is a terminal') is self-consistent, but the headline AGENTS.md guarantee and the practical goal of protecting the human terminal fail in the default invocation.

Reproduction:

```
python3 -c "import subprocess; p=subprocess.run(['docker','run','--rm','--platform','linux/arm64','-e','KCOS_EXEC=x\x1b[31mPWN\x07\x7f','kcontaineros','true'],capture_output=True); print(repr(p.stderr))"  -> stderr contains raw 0x1b,0x07,0x7f. Also: docker run --rm -e $'E=\x1b[31mPWN\x07\x7f' kcontaineros sh -c 'nosuch"$E"' (raw bytes in 'sh: nosuch...: not found'). Harness: audit/escape-user/04-terminal.py.
```

Expected: Per AGENTS.md 'Nothing untrusted reaches a terminal raw' and README 'every error message that goes to a terminal ... replace everything but printable ASCII': the operator's terminal should never receive raw non-printable bytes from attacker-controlled input.

Observed: Without -t, init/shell/utility messages emit raw ESC (0x1b), BEL (0x07), DEL (0x7f) etc. straight through to the operator's terminal; only the -t case is sanitized.

Reviewer: The behaviour is real but is what both documents state: sanitising is conditional on the process's own output being a terminal, as with ls everywhere, and piped output is byte-exact. The auditor's reading of AGENTS.md quotes the heading and omits the qualifying sentence. No ability is gained: whoever controls the image's ENV or the arguments also chooses the command, which can write arbitrary bytes to the same pipe that Docker relays. At most a README note that without -t Docker forwards the pipe to the caller's terminal unfiltered.

### F3 — README limit understates who can change program-file permissions and timestamps: the owning user, not only root

- Severity: auditor **low**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: README.md Security limits ('Root can still change the permissions and timestamps of files it owns'); observed on a third-party image

The README attributes changing permissions and timestamps of files in program directories to 'root'. In a third-party image that does COPY --chown=65534 of its app into a program directory, the files are owned by nobody, the default user, which can then chmod and touch them. File contents remain immutable and no_new_privs neuters any setuid/setgid bit, so impact is low, but the documentation attributes a security-relevant metadata-change ability to root only.

Reproduction:

```
docker run --rm --platform linux/arm64 kcos-audit-escape-user-third busybox sh -c 'chmod 0500 /app/bin/kp; echo chmod=$?; touch -d "2001-01-01 00:00:00" /app/bin/kp; echo touch=$?; stat -c %a /app/bin/kp'  (built by audit/escape-user/build.sh). Harness: audit/escape-user/02-write-read.sh (third-party program directory section).
```

Expected: Per README, only root changes permissions/timestamps of program-directory files.

Observed: chmod=0 and touch=0 as the default unprivileged user nobody (the file's owner); contents still immutable.

Reviewer: Happens only when the image builder chowns program files to the run-time user (COPY --chown=65534); in the stock image they are root-owned and nobody is refused (chmod /bin/sh: Operation not permitted). Contents stay immutable; a setuid bit on a file owned by nobody grants nothing and no_new_privs is set. The README limit is true but names only root where it should say the file's owner: a wording gap, not a false claim, hence info rather than the auditor's low. Verdicts and evidence written to audit/escape-user/REPRODUCTION.md; no containers or images of mine remain.

