# Track: seccomp

What the auditor of this track reported, unedited apart from layout, and what the
independent reviewer made of each finding. The state of the tree is that of 0.2.0
(commit `deffcb4`); what was done about each finding is in [../README.md](../README.md).

## What was exercised

Seccomp track, kContainerOS 0.2.0 (deffcb4), kernel 7.0.14-linuxkit. The filter held: no bypass, no jump or accumulator error, no truncation or arch gap, and every documented refusal is real. Two low findings sit around the filter, not in it.

REPORT.md was NOT written: the Write tool refused report files for subagents, and I did not work around that. Its content is this result; the raw evidence is in audit/seccomp/out/ (run.log, static.txt, table.tsv, compare*.txt).

(a) Method used: PTRACE_SECCOMP_GET_FILTER worked on this kernel, so the bytes come from the kernel, not from src/lock.rs. I read 12 programs from 11 processes in 5 containers (release as root/privileged, release as nobody with Docker's filter on, sealed, shell without init, init plus docker exec). There are three distinct programs:
- init's, 153 instructions, 8 byte-identical copies (release and sealed alike);
- the outside-init shell variant, 2 copies, differing in one instruction (the probe constant);
- Docker's default, 829 instructions.
No process carried a second kContainerOS filter.

(b) Interpreter (bpf.py) on the dumped bytes:
- Static pass: 74 conditional jumps (1 on arch, 6 on the low half of arg0, 67 on the number); none reachable with two kinds of value in the accumulator, none out of range, nothing unreachable, no path without a return.
- Table for 0..1100 under aarch64: 405 ALLOW, 61 EPERM, 635 ENOSYS (clone3 and 467..1100). It is in out/table.tsv.
- Argument clauses (clone, socket, personality, prctl): 4050 boundary evaluations; the high 32 bits of arg0 and the other arguments never change a verdict.
- Foreign arch: 44 values x 1104 numbers x 5 arg0 values = 242,880 evaluations, all KILL_PROCESS.
- Numbers 467..69,999 and 0..466 with any one of bits 9..31 set: all ENOSYS.
- The 61 DENIED entries in src/lock.rs are exactly the 61 unconditional EPERM numbers in the kernel's copy.

(c) Claims: 44 (claim, syscall) pairs from the README and docs/llms.txt are all refused by the installed filter; 74 related calls are listed with their verdict. Against Docker's default (dumped and interpreted the same way), get_mempolicy is the only call Docker refuses that kContainerOS allows among numbers it knows.

(d) Calls from a static helper, as root with --privileged and seccomp=unconfined:
- Sample under init vs without init: 136 calls, 98 distinct numbers. Of 90 refuse verdicts the kernel agreed on all 90, and the control answered differently in 85 (the other 5 are numbers no kernel has). Of 46 allow verdicts, 39 matched the control and 7 differ only for lack of a capability.
- Same 136 under the sealed image's init: identical line for line. As nobody with Docker's filter on: no disagreement with any refuse verdict.
- All 696 numbers in 0..1100 with an unconditional refuse verdict, called under init: 61 EPERM and 635 ENOSYS, exactly as interpreted.
- AF_VSOCK under init only: 5 socket calls EPERM, socketpair EOPNOTSUPP.
- Also run: filter stacking (3 added filters), execveat on 7 targets, /proc/PID/mem in 5 configurations, docker exec, and init under a pre-existing filter.

Cleanup: the three kcos-audit-seccomp-* helper images are removed and no container or volume is left; run.sh rebuilds them. One unnamed container of mine (a control run that blocked as PID 1) hung during development and was removed with docker rm -f; probe.sh now names every container and removes it on timeout. Nothing outside audit/seccomp/ was written.

## What held

- The filter in the kernel is the one in src/lock.rs: 153 instructions, identical for PID 1 and its descendants in the release image (root/privileged and nobody/Docker default) and the sealed image; exactly one kContainerOS filter per process under init.
- A shell or utility started outside init (--entrypoint, docker exec) carries the same program with only the probe constant changed (answers KCOS, not KCOF).
- No jump-offset or accumulator error: all 67 number comparisons see the syscall number, all 6 argument comparisons see the low half of arg0, the single arch comparison sees arch; every path ends in a return.
- Every syscall behind a README or llms.txt refusal claim is refused by the installed filter and from a real process under init, and reaches the kernel without init. Covered: ptrace, process_vm_readv/writev, unshare, setns, clone with each of the 7 namespace flags, clone3 (ENOSYS), the mount family including the new mount API, chroot, pivot_root, module calls, bpf, io_uring_*, perf_event_open, add_key/request_key/keyctl, clock and hostname calls, memfd_create, memfd_secret, personality other than 0 or query. socket(AF_VSOCK) is refused under init as well, but has no control run (vsock without init was forbidden).
- All 61 EPERM numbers and all 635 ENOSYS numbers in 0..1100 return exactly that errno when called under init as root with --privileged and seccomp=unconfined.
- Numbers newer than the filter knows (467..470 exist on this kernel) get ENOSYS under init and EFAULT/EINVAL without it; 466 (removexattrat) is still let through.
- No 32-bit truncation gap: x8 with bit 32 set is treated as the low 32 bits by kernel and filter alike (memfd_create refused under init, created in the control); high-half bits in clone flags, socket family, personality and the prctl option never change a verdict; namespace flags placed only in the high half are ignored by the kernel.
- Foreign arch values are KILL_PROCESS for every number (interpreter on the dumped bytes only; 44 arch values).
- A process cannot undo a refusal by adding filters: after an allow-all filter and a USER_NOTIF filter memfd_create still returns EPERM; an ERRNO(0) filter makes the caller see 0 but no memory file exists.
- execveat is let through by the filter but cannot start a copy of a program placed in /tmp (by path, O_PATH + AT_EMPTY_PATH, unlinked descriptor, /proc/self/fd/N, O_TMPFILE): EACCES under init, all run in the control.
- socketpair(AF_VSOCK) passes the filter but yields no socket (EOPNOTSUPP).
- prctl is not otherwise filtered, and what it could loosen is refused by the kernel under init: PR_SET_NO_NEW_PRIVS 0 gives EINVAL, PR_SET_SECUREBITS and PR_SET_MM give EPERM; setgroups, raw and packet sockets and setpriority fail for lack of capabilities.
- /proc/1/mem cannot be opened by nobody or by root under init (PID 1 is not dumpable).
- With Docker's filter off, the only call in Docker's default block list that the kContainerOS filter lets through is get_mempolicy (ENOSYS on this kernel, no NUMA).
- docker exec behaves as the README says: a kContainerOS utility gets the filter and no_new_privs but keeps full capabilities in a privileged container; another program gets neither.

## Not tested

- REPORT.md was not written: the Write tool refused report files for subagents and I did not circumvent it. Scope, method, counts, results and limits are in this structured result; evidence is in audit/seccomp/out/.
- A foreign-architecture process against the real filter: the host CPU has no AArch32 at EL0 and the kernel no compat entry, so KILL_PROCESS for foreign arch values is the interpreter's result on the dumped bytes only.
- Allowed syscalls exhaustively from a real process: only 46 allow-verdict calls were made, because calling all 405 allowed numbers with arbitrary arguments is unsafe (exit, kill, pause, sync). For the rest the evidence is the interpreter on the kernel's bytes.
- Kernel module autoloading through socket() for a family whose module is not loaded (the filter allows every family except AF_VSOCK): trying it would load modules into the VM shared with the other auditors.
- AF_VSOCK without init (forbidden by the rules), so the vsock refusal has no control run; the EPERM matches the interpreter.
- ptrace(PTRACE_TRACEME) (forbidden by the rules); ptrace was called with PEEKDATA and SEIZE on a nonexistent PID instead.
- Yama ptrace_scope (not present on this kernel), so the README's 'unless the host enables Yama' is unverified.
- Other kernels and runtimes: native Linux hosts, kernels other than 7.0.14-linuxkit, Kubernetes, user namespaces, gVisor.
- Same-user syscalls aimed at PID 1 that the filter lets through (prlimit64 set, sched_setaffinity and the like): only read-only variants were called; their effect on init belongs to the init track.
- docs/index.html was only searched for filter claims (it carries the same table row and limit as the README), not read in full.
- The docker build with 'apk add gcc' failed with an I/O error (Docker disk 98% full), so the helpers are compiled in the local rust:1-alpine image; syscall names come from musl's headers there (326 names up to 470).

## Findings

### S1 — Another process's memory can be read and written under init through /proc/PID/mem, while the Security table says it is refused

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced, already documented
- Where: README.md:99 (Security table, 'Reduced kernel surface'), README.md:157-159 (limit), docs/index.html:541, docs/llms.txt:26 and its 'What it does not do' list; src/lock.rs DENIED (process_vm_readv/writev, ptrace)

The table row says reading or writing another process's memory is refused. The filter refuses process_vm_readv, process_vm_writev and ptrace, but /proc/PID/mem is a file the filter never sees. As the image's default user under init, a process read a sibling's memory and wrote into it, including into a read-only page. As root under init (also with --privileged) the read succeeded and only the open for writing was refused, by Landlock on /proc. The README's limits list does disclose the write ('Processes of the same user can write each other's memory through /proc/PID/mem unless the host enables Yama'), so this is a documentation inconsistency plus an understated limit. The table row is unqualified; the limit does not mention reading (which root can do too) or that the write goes through read-only mappings; docs/llms.txt carries the claim without the limit. Yama is absent on this host, so the 'unless Yama' part could not be checked.

Reproduction:

```
# from the repository root
KEEP=1 audit/seccomp/run.sh    # builds kcos-audit-seccomp-probe (kcos-audit + audit/seccomp/helpers/sysprobe.c in /bb)
timeout 120 docker run --rm --platform linux/arm64 --user 65534:65534 kcos-audit-seccomp-probe /bb/sysprobe mem
timeout 120 docker run --rm --platform linux/arm64 --user 0:0 kcos-audit-seccomp-probe /bb/sysprobe mem
# control: add --entrypoint /bb/sysprobe and drop '/bb/sysprobe' from the command
```

Expected: Per the table row: both the read and the write of the other process's memory are refused under init, as process_vm_readv is.

Observed: User 65534 under init: / attacker: uid 65534, victim is a sibling process / attacker: process_vm_readv -> Operation not permitted / attacker: read 15 bytes of victim memory: "ORIGINAL-SECRET" / attacker: wrote 15 bytes into victim memory / attacker: wrote 17 bytes into a read-only page of the victim / attacker: open /proc/1/mem for reading: Permission denied / victim: writable buffer now "TAMPERED-SECRET" / victim: read-only buffer now "READONLY-TAMPERED" /  / User 0 under init (same with --privileged --security-opt seccomp=unconfined): / attacker: process_vm_readv -> Operation not permitted / attacker: read 15 bytes of victim memory: "ORIGINAL-SECRET" / attacker: open /proc/VICTIM/mem for writing: Permission denied / victim: writable buffer now "ORIGINAL-SECRET"

Reviewer: The behaviour is exactly as reported, but the README already lists it as a limit, so it is not an undisclosed hole. What remains is wording. (1) The table row at README.md:99 and docs/index.html:541 says "reading or writing another process's memory ... are refused" without qualification; that is true only of the system calls. (2) The limit names writing only; reading works too, and root can read as well (root's write is stopped by Landlock on /proc). (3) docs/llms.txt lacks the limit, but the auditor's statement that it "carries the claim" is wrong: line 26 lists only ptrace, namespaces, mounts, bpf, io_uring, memfd_create "and similar". PID 1 stayed unreadable in every run under init, as README.md:101 claims. The "unless Yama" part could not be checked on this host. Agree with low: a documentation fix plus a suite check.

### S2 — Init treats errno 114 from any earlier seccomp filter as proof of lockdown and then silently applies no no_new_privs, no Landlock and no filter

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/lock.rs:45-49 (lockdown: early return on prctl(probe) == -EALREADY); README.md:171 ('if the filter itself cannot be installed, init refuses to start')

lockdown() returns before PR_SET_NO_NEW_PRIVS, confine_files and install_filter when prctl(0x4b434f46) answers EALREADY. That answer normally comes from kContainerOS's own filter, but any filter installed before init can give it. With a Docker seccomp profile that returns errno 114 for that prctl, init started the command with NoNewPrivs 0, only Docker's filter, no Landlock (a copy of busybox in /tmp was started; memfd_create reached the kernel) and no warning. Capabilities were still dropped. Only whoever starts the container can cause this, and the profile has to be written for it, so it is not reachable from inside; it is a path where the lockdown fails open and silently instead of closed.

Reproduction:

```
# from the repository root
KEEP=1 audit/seccomp/run.sh    # or: audit/seccomp/extra.sh once the helper images exist
timeout 120 docker run --rm --platform linux/arm64 --security-opt seccomp=audit/seccomp/helpers/ealready.json kcos-audit-seccomp-probe /bb/busybox sh -c "/bb/busybox grep -E 'NoNewPrivs|Seccomp|CapEff' /proc/self/status; /bb/sysprobe raw 279; /bb/busybox cp /bb/busybox /tmp/busybox && /tmp/busybox echo 'A COPY OF BUSYBOX IN /tmp WAS STARTED'"
# control: the same command without --security-opt
```

Expected: As without the profile: / CapEff: 0000000000000000 / NoNewPrivs: 1 / Seccomp: 2 / Seccomp_filters: 2 / raw 279 117 0 errno:1 / sh: line 0: /tmp/busybox: Permission denied / (or init refusing to start)

Observed: CapEff:	0000000000000000 / NoNewPrivs:	0 / Seccomp:	2 / Seccomp_filters:	1 / raw 279	117	0	errno:14 / A COPY OF BUSYBOX IN /tmp WAS STARTED / (no warning on stderr)

Reviewer: Real and not documented, but not reachable from inside a container: only whoever starts the container can supply the profile, it has to target prctl(0x4b434f46) with errno 114 specifically, and that person could equally pass --entrypoint, which the README does document as running outside init. No privilege is gained past the lockdown by anything running in the container. It is still a silent fail-open path in code whose stated rule is to fail closed (README.md:171, AGENTS.md), so low is right, not info. On the stock image the damage is narrower than the auditor's probe image suggests: kContainerOS's own shell and utilities still filter themselves, and what is lost is Landlock and init's filter for other programs. The suggested fix (init as PID 1 never trusts the probe, or verifies the state) is sound. Evidence is written to audit/seccomp/REPRODUCTION.md; the image kcos-audit-vseccomp-probe was removed and no containers are left.

