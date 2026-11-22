# kContainerOS 0.2.0 security audit — track `escape-user`

Scope: a hostile workload running as the **default user (`nobody`, 65534)** under
init, in realistic Docker configurations. Commit `deffcb4`. Host: macOS arm64,
Docker Desktop, kernel 7.0.14-linuxkit, `--platform linux/arm64`.

Threat model: the attacker already has code execution inside the container (a
hijacked tool server / agent). Goals exercised: run code written at run time,
write/read where the README forbids, exhaust or mislead init, hide processes from
cleanup, survive stop, make init report a wrong status, inject terminal escapes,
and influence init through attacker-controlled environment (`docker run -e` or a
Dockerfile `ENV`). Every refusal is paired with a control run **without** init
(`--entrypoint /bb/busybox`), where it must succeed.

## Method and what was exercised

All evidence is from real containers. Reproducible harness (run from the repo root):

- `build.sh` — compiles static helpers (`helper/kp.c`, `payload.S`, `evil.c`) in
  the project's own `rust:1-alpine` image; builds three images.
- `01-run-written-code.sh` — 44 execution routes (`inside/exec-routes.sh`) across
  17 configurations, each under init and as a control.
- `02-write-read.sh` — writable-directory sweep (`inside/writable.sh`) × 9
  configs; program-directory immutability; volume-in-/usr; `KCOS_EXEC` ignored
  entries; `--device`; PID-1 opacity; Docker-Desktop host share.
- `03-init.sh` — exit-status pass-through, signal storms, leftover cleanup (PID 1
  and `--pid host`), PID-churning leftovers, `docker stop`, environment-only
  influence.
- `04-terminal.py` — 50+ messages from init/shell/utilities on a real pty,
  scanning for non-printable bytes; also the no-`-t` case.
- `05-sessions-limits.sh` — `docker exec` reach, `--pid host` cross-container
  reach, TIOCSTI, no-Landlock behaviour, `nofile`, `noexec`, argv tricks.

Images: `-img` (`kcos-audit` + `kp` in `/bb`, run `-u 65534:65534`); `-third`
(`FROM kcontaineros` + app in `/app/bin` + `ENV KCOS_EXEC=/app/bin`, user nobody);
`-sealed` (`FROM kcontaineros:sealed` + tools named by `KCOS_EXEC`, README agent
recipe). Counts: ~700 start attempts under init (0 started a run-time program);
9 writable sweeps; 10 exit-status checks; 12 seccomp probes; ~50 terminal cases.

## Findings

### F1 (medium) — `KCOS_EXEC` entries ignored as "not a plain absolute path" leave their top-level directory writable, contradicting the README

README: *"a trailing slash, `.` or `..` components and anything reached through a
symbolic link are ignored, with a warning. The top-level directory of an ignored
entry is not writable all the same."* For exactly that class the directory stays
writable:

    $ docker run --rm --platform linux/arm64 -u 65534:65534 \
          -e KCOS_EXEC=/tmp/ kcos-audit-escape-user-img /bin/sh -c \
          'echo x > /tmp/f; echo "write-to-/tmp=$?"'
    kcontaineros: warning: KCOS_EXEC: /tmp/ is not a plain absolute path: ignored
    write-to-/tmp=0        # README expects refused (=1); ACTUAL: written

Same for `/tmp/.`, `/tmp/../tmp`, `//tmp`. A valid `/tmp` or a `/tmp/sub` rejected
for "not a directory" both correctly give `write-to-/tmp=1`. Root cause
(`src/lock.rs`): `absolute_dirs()` filters trailing-slash/`.`/`..` entries before
the `holds_programs` test, so the top-level dir is never marked program-holding
and gets write in the root sweep; entries that fail later (at `allow()`) still
feed `holds_programs` and so do protect their directory — hence the inconsistency.
Impact: documentation / defense-in-depth; no code-exec escape (dir is writable but
not an exec dir — nothing written there starts).

### F2 (medium) — Terminal-escape sanitization is bypassed when the container's output is not itself a tty (default `docker run` without `-t`)

AGENTS.md: *"Nothing untrusted reaches a terminal raw."* README: *"every error
message that goes to a terminal … replace everything but printable ASCII."*
Sanitization in `util::eprint` / `Out::safe` is gated on `isatty(fd)` of the
container process's own descriptor. Without `-t` that fd is a pipe, so no
sanitization — but Docker copies it to the operator's real terminal.

    $ docker run --rm -e $'KCOS_EXEC=x\x1b[31mPWN\x07\x7f' kcontaineros true
    stderr = b'kcontaineros: warning: KCOS_EXEC: x\x1b[31mPWN\x07\x7f is not a plain absolute path: ignored\n'
    raw bytes present: 0x1b ESC, 0x07 BEL, 0x7f DEL

Same raw bytes from `sh: nosuch\x1b[31mPWN\x07\x7f: not found` and `cat: /no…`.
With `-t` the identical cases are sanitized to `?`. Most realistic delivery: a
malicious base image with `ENV KCOS_EXEC=<escape>`; init prints the ignored-entry
warning on every run, so `docker run that-image` (no `-t`) at a terminal receives
the escape. Impact: terminal injection / operator deception; no escape or
privilege gain. The README's exact wording ("when the output is a terminal") is
self-consistent, but the headline guarantee and the practical goal fail in the
default invocation — hence medium (misleading docs on a security matter).

### F3 (low) — README understates who may change program-file metadata

README limit: *"Root can still change the permissions and timestamps of files it
owns, in program directories too."* Reality: the file's **owner** can, which in a
third-party image (`COPY --chown=65534`) is the default unprivileged user.

    # /app/bin/kp owned by nobody, default user nobody:
    chmod 0500 /app/bin/kp -> chmod=0 ; touch -d 2001-01-01 /app/bin/kp -> touch=0

Contents stay immutable (create/append/rm/mkdir all refused); `no_new_privs`
neuters any setuid bit. Low impact; the README phrases it as root-only.

## What held (no findings)

- Run-or-write rule: across 17 configs (plain, `--read-only`, named volume,
  `--tmpfs …:exec`, `/dev/shm` ±exec, `--ipc/--pid/--network host`, `-p`,
  `--device`, `--privileged --cap-add ALL`, root `--privileged`, `--init`,
  `seccomp=unconfined apparmor=unconfined`, alt uid, third-party, sealed agent
  recipe) 0 of 44 execution routes started a run-time program under init; controls
  started 13–24. Routes include direct/PATH/env/`sh -c`/exec/command, symlink,
  shebang, no-shebang text, `/proc/self|1/root`, `/proc/self/cwd`, relative,
  `/dev/fd`, `/proc/self/fd`, `execveat(AT_EMPTY_PATH)`, `execve(/proc/self/fd/N)`,
  `O_TMPFILE`, `memfd_create`, SysV-shm `map_files`, `/proc/self/exe` re-exec with
  crafted argv[0], nested init, `LD_*`. Documented interpreter/in-process routes
  (`sh FILE`, `sh < FILE`, `mmap(PROT_EXEC)`, read-into-anon-memory) run as stated.
- Writing/reading: writable set under init is exactly the documented one
  (`/tmp /var/tmp /dev/shm`; `--ipc none` drops `/dev/shm`; `--read-only` leaves
  only the tmpfs; sealed recipe leaves only `/work`). Program dirs and a volume in
  `/usr` are immutable; `/proc`,`/sys` not writable for root; PID-1
  environ/mem/fd/maps/exe/root/cwd/auxv/io refused; host share read-only,
  non-exec, and unreadable once `/dev` is unusual.
- Devices: unnamed `--device` not openable, `KCOS_DEV`-named one openable; device
  mapped outside `/dev` is an ordinary file (documented limit).
- Seccomp (root, `--privileged`, `seccomp=unconfined`): memfd_create,
  memfd_secret, ptrace, process_vm_readv, io_uring_setup, bpf, userfaultfd, vsock,
  CLONE_NEWUSER, unshare refused; clone3 and >NEWEST_KNOWN give ENOSYS;
  socket(AF_INET) and threading clone allowed. NoNewPrivs:1, Seccomp:2, CapEff:0
  everywhere; CapBnd:0 as root, inert non-empty as nobody (documented).
- init: correct exit status (0/7/255; 137/143/139; 127/126; command's own, not an
  orphan's); survives SIGKILL/SIGSTOP, 5000 forwarded signals, 2000-orphan storm;
  cleans up setsid/double-fork/stopped/SIGTERM-ignoring/PID-churning leftovers as
  PID 1 and under `--pid host`; `docker stop` → 143 at once, 137 at timeout.
- Environment: ENV/BASH_ENV/IFS/PS1/PS4/PWD/OLDPWD/SHELLOPTS/CDPATH do not steer
  the shell; IFS unchangeable; PATH/LD_* at a written file inert; KCOS_EXEC cannot
  name /dev,/proc,/sys.
- Sessions: workload cannot open a `docker exec` session's or another container's
  (`--pid host`) memory/root/environ/fd/cwd/maps, nor exec through its
  /proc/PID/root; TIOCSTI refused (kernel). exec shell has nnp+filter, keeps caps,
  outside Landlock (documented).
- No-Landlock fallback (simulated via seccomp erroring landlock_*): warns, rule
  off, filter on. Low `nofile` cannot create a silent fallback (runtime refuses to
  start first).

## Could NOT test

- A genuinely Landlock-less or pre-5.19 kernel (only simulated the syscall
  failures); non-Docker-Desktop / native-Linux bind-mount behaviour; user-ns
  remapping, Kubernetes, rootless Docker (untested per README); TIOCSTI on a
  kernel with legacy_tiocsti enabled (disabled globally here); whether F2's bytes
  drive a specific terminal emulator to a concrete action (confirmed only that raw
  bytes reach a pty).

## Housekeeping

Containers/volumes named `kcos-audit-escape-user-*` were removed. Three images
remain so the harness re-runs; remove with
`docker images -q 'kcos-audit-escape-user-*' | xargs docker rmi -f`. No prune or
restart; no kernel file/device written (append-and-close only); no block device or
vsock opened in a control run.
