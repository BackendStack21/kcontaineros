# Independent reproduction of the "seccomp" track findings

Host kernel 7.0.14-linuxkit (Docker Desktop, arm64); Yama not present
(`/proc/sys/kernel/yama/ptrace_scope` does not exist). The auditor's helper
images were gone; the probe image was rebuilt from
`helpers/Dockerfile.tools --target probe` as `kcos-audit-vseccomp-probe`
and removed afterwards. Every container ran as `--rm --name kcos-audit-vseccomp-a`.

## S1 - /proc/PID/mem under init: reproduced_but_documented (low)

```
$ docker run --rm --platform linux/arm64 --user 65534:65534 kcos-audit-vseccomp-probe /bb/sysprobe mem
attacker: uid 65534, victim is a sibling process
attacker: process_vm_readv -> Operation not permitted
attacker: read 15 bytes of victim memory: "ORIGINAL-SECRET"
attacker: wrote 15 bytes into victim memory
attacker: wrote 17 bytes into a read-only page of the victim
attacker: open /proc/1/mem for reading: Permission denied
victim: writable buffer now "TAMPERED-SECRET"
victim: read-only buffer now "READONLY-TAMPERED"

$ docker run --rm --platform linux/arm64 --user 0:0 kcos-audit-vseccomp-probe /bb/sysprobe mem
  (identical with --privileged --security-opt seccomp=unconfined)
attacker: uid 0, victim is a sibling process
attacker: process_vm_readv -> Operation not permitted
attacker: read 15 bytes of victim memory: "ORIGINAL-SECRET"
attacker: open /proc/VICTIM/mem for writing: Permission denied
attacker: open /proc/1/mem for reading: Permission denied
victim: writable buffer now "ORIGINAL-SECRET"
victim: read-only buffer now "READONLY-ORIGINAL"

control, no init: --entrypoint /bb/sysprobe ... mem   (65534 and 0 alike)
attacker: process_vm_readv -> allowed
attacker: read 15 bytes of victim memory: "ORIGINAL-SECRET"
attacker: wrote 15 bytes into victim memory
attacker: wrote 17 bytes into a read-only page of the victim
attacker: /proc/1/mem opened, read -> data
victim: writable buffer now "TAMPERED-SECRET"
victim: read-only buffer now "READONLY-TAMPERED"
```

The behaviour is exactly as reported. README.md:157-159 already lists it
among the limits ("Processes of the same user can write each other's memory
through `/proc/PID/mem` unless the host enables Yama. Run one service per
container."), and docs/index.html:808 carries the same sentence. What is
left is wording:

- README.md:99 / docs/index.html:541 say "reading or writing another
  process's memory ... are refused" without qualification; true only of
  the system calls (process_vm_readv/writev, ptrace).
- The limit names writing only. Reading works too, and for root as well
  (root's write is stopped by Landlock on /proc, its read is not).
- The auditor's statement that docs/llms.txt "carries the claim" is not
  accurate: llms.txt:26 lists only "`ptrace`, new namespaces, mounts, `bpf`,
  `io_uring`, `memfd_create` and similar". It does lack the limit.
- PID 1 stays unreadable in every run under init, as README.md:101 claims.

## S2 - errno 114 from an earlier filter makes init skip the lockdown: reproduced (low)

```
$ CMD="/bb/busybox grep -E 'NoNewPrivs|Seccomp|CapEff' /proc/self/status; /bb/sysprobe raw 279; /bb/busybox cp /bb/busybox /tmp/busybox && /tmp/busybox echo 'A COPY OF BUSYBOX IN /tmp WAS STARTED'"
$ docker run --rm --platform linux/arm64 kcos-audit-vseccomp-probe /bb/busybox sh -c "$CMD"
CapEff:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
Seccomp_filters:	2
raw 279	117	0	errno:1
sh: line 0: /tmp/busybox: Permission denied
rc=126

$ docker run --rm --platform linux/arm64 --security-opt seccomp=helpers/ealready.json kcos-audit-vseccomp-probe /bb/busybox sh -c "$CMD"
CapEff:	0000000000000000
NoNewPrivs:	0
Seccomp:	2
Seccomp_filters:	1
raw 279	117	0	errno:14
A COPY OF BUSYBOX IN /tmp WAS STARTED
rc=0
```

Additional runs of mine:

```
release image, default user, with the profile (the shell and utilities still lock themselves down, Landlock is gone):
$ docker run --rm --security-opt seccomp=helpers/ealready.json kcontaineros sh -c 'cat /proc/self/status'
Uid: 65534  CapEff: 0000000000000000  NoNewPrivs: 1  Seccomp: 2  Seccomp_filters: 2
$ ... kcontaineros sh -c 'cp /bin/sh /tmp/x; chmod 755 /tmp/x; /tmp/x -c "echo ..."; echo rc=$?'
without profile:  sh: /tmp/x: permission denied / rc=126
with profile:     kcontaineros: x: applet not found / rc=127     <- the copy in /tmp was executed
$ ... kcontaineros true 2>&1 >/dev/null | wc -c
0                                                             <- no warning
with --security-opt no-new-privileges added to the profile run of the probe image:
NoNewPrivs: 1, Seccomp_filters: 1, raw 279 errno:14, A COPY OF BUSYBOX IN /tmp WAS STARTED
```

Cause: src/lock.rs:45-49 returns before PR_SET_NO_NEW_PRIVS, confine_files
and install_filter when prctl(0x4b434f46) answers -114, whoever answered.

Not reachable from inside a container: only whoever starts it can supply
the profile, and that person could equally pass `--entrypoint`. It is
still a silent fail-open path in code whose stated rule is to fail closed
(README.md:171, AGENTS.md "Fail closed in the lockdown"), and the README
does not mention it. Severity low.
