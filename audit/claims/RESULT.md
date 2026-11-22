# Track: claims

What the auditor of this track reported, unedited apart from layout, and what the
independent reviewer made of each finding. The state of the tree is that of 0.2.0
(commit `deffcb4`); what was done about each finding is in [../README.md](../README.md).

## What was exercised

Track "claims" on kContainerOS 0.2.0 (deffcb4), Docker Desktop 29.9.3, kernel 7.0.14-linuxkit, with other audit tracks on the same daemon.

REPORT.md was not written: the Write tool refuses report files from a subagent, and I did not work around it. Its content is this result plus the logs the harness leaves in audit/claims/out/ and audit/claims/mutants/.

(a) Claims: 129 numbered claims from README.md, docs/index.html and docs/llms.txt, 391 experiments in real containers; 384 held, 7 did not (5 claims).
- The one security claim that failed: a device named in KCOS_DEV inside a subdirectory of /dev makes every other device of that subdirectory readable, a host block device included.
- The other four are low or info: a README sentence about ignored KCOS_EXEC entries, SIGCHLD not forwarded, `ls -a` without `.` and `..`, and an undocumented /dev/termination-log entry in the allowlist.
- The Security table was run as root with --privileged and seccomp=unconfined, each refusal with a control without init. Sweeps counted as one experiment each: 346 device nodes (44 block) opened for reading and appending, 5111 /proc and /sys files opened for appending, all 61 refused syscall numbers, 137 numbers above the newest known, 34 named calls with controls.
- All three terminal sessions on the page reproduce character for character, though the PIDs shown (7, 8) depend on the runtime.
- Every recipe was run as written except the `apk add` stage.
- The three documents do not disagree with each other in substance.

(b) Mutants: 17 runs of the project's suite (unmodified sources 3 times, 13 mutants, m1 twice), one after another.
- Of the 8 asked for, 3 were killed (m2 vsock, m4 symlink following, m5 dumpable) and 5 survived (m1 process_vm_writev, m3 /sys writable for root, m6 truncation, m7 /dev/shm execute, m8 file removal).
- Of 5 extra mutants, 2 were killed (m9 no filter, m10 no SIGKILL) and 3 survived (m11, m12, m13).
- Each survivor was rebuilt and the hole exercised. m7 only shows with /dev/shm mounted exec, m12 and m13 are still refused by the capability drop, and m11 only loses a warning.
- The suite is flaky here: the unmodified sources failed one check in each of 3 runs, and 15 of 17 runs had at least one failure unrelated to the code.
- The suite's control sets the Docker VM clock to 2001-01-01 on every run; this was observed 8 times, for 11 to 27 s each.

(c) Suite reading: 12 grep-only terminal checks, one refusal check that passes identically without init, refusals without controls, and status-only checks; these are listed in finding C-12.

Measured: binary 90240 bytes; image 236206 bytes (239kB in `docker images`); rootfs layer 180kB; sealed image 98642 bytes; 19 utilities. Alpine 3.24.4: 13.6MB, layer 9.31MB, busybox 919 kB, 304 applets, musl 723 kB, 16 packages. `docker stop` on `sleep 300`: 102 to 181 ms with exit 143, against Alpine's 3201 ms with exit 137 (10202 ms with -t 10, 150 ms with --init). `docker run --rm IMAGE true` took 331 to 404 ms against Alpine's 352 to 511 ms on a busy machine, so the README's 170 to 192 ms could not be confirmed; the relation holds.

To rerun from the repo root: audit/claims/build.sh, then audit/claims/claims.sh (about 4 minutes), audit/claims/mutants.sh (about 2.5 minutes per mutant) and audit/claims/mutant-effect.sh. The helper images were removed at the end and build.sh recreates them; nothing of mine is left in Docker.

## What held

- Sizes and counts: binary under 100 kB (90240 bytes), image under 250 kB (236206; 239kB), rootfs layer 180kB, sealed about 100 kB (98642), 19 utilities plus sh and init, four files in /etc, every link resolves to the one binary
- Binary: static PIE, no interpreter, no DT_NEEDED, RELRO, no W+X segment, non-executable stack; code, stack and heap at different addresses on three starts; .eh_frame present, no BTI note
- Reproducible: a --no-cache rebuild of this checkout gives the identical layer as the prepared image, for the default and the sealed target; the binary embedded in docs/index.html is the image's; tools/update-docs.sh on a copy changes nothing; FAQ JSON-LD equals the visible questions
- No capabilities: all five sets empty with NoNewPrivs 1 and Seccomp 2 as root under --privileged and under --cap-add ALL (control: full set without init)
- no_new_privs: a setuid-root binary and a binary with file capabilities grant nothing to nobody under init; without init they grant euid 0 and CapEff 0x401
- Run or write: copies of a static binary in /tmp, /var/tmp, a volume and an exec tmpfs do not start for privileged root (control: all start)
- Run or write: create, mkdir, symlink, hardlink, mkfifo, remove, rmdir, rename, move in or out, append, truncate (shell and truncate(2)), overwrite and renameat2 in program directories all refused after chmod 777 (control: all succeed)
- memfd_create and memfd_secret refused
- Symbolic links made before init starts (top-level, inside /tmp, /data -> /usr/share/x) do not make a program directory writable (control: they do without init)
- Devices: of 346 device nodes in a privileged /dev (44 block devices) only null, zero, full, random, urandom and pts/ptmx open, for reading or appending; tty, console and the pts terminal open with a terminal; an unnamed top-level --device is closed and opens when named; the /dev/fuse recipe works
- /proc and /sys: 5111 files with the owner's write bit, none opens for appending as privileged root (control: four files open without init); root cannot open its own oom_score_adj, nobody can
- Seccomp: 34 named calls (ptrace, process_vm_readv/writev, unshare, setns, mount family, chroot, modules, bpf, io_uring, perf, keyrings, clock, hostname, personality, clone with six namespace flags) answer EPERM under init and none does in the control; AF_VSOCK refused; all 61 numbers of the refusal list refused; 467..600, 1000, 65535 and 2^32-1 answer ENOSYS; clone3 answers ENOSYS
- PID 1 opaque: environ, mem, maps, exe and cwd of PID 1 refused to nobody and to privileged root (control: readable without init)
- init: exit status passes through (0, 1, 42, 255, 137, 143, 139); 28 of 29 standard signals and real-time signals 34 and 64 forwarded; orphans reaped (control: 3 zombies without init); docker stop 102 to 181 ms with exit 143; shell-form command replaced by its last command; nested init stops leftovers at once, or after about 2 s if they ignore SIGTERM
- PID 1 idle: no context switch and no CPU tick in 5 s, one thread, SigCgt 0, no heap in its memory map
- docker exec sh: NoNewPrivs 1 and Seccomp 2, Docker's capabilities kept, not under Landlock; docker exec of another program gets none of it; --entrypoint removes everything
- All three terminal sessions of the page reproduce character for character (the PIDs 7 and 8 depend on the runtime)
- Recipes as written: FROM kcontaineros with COPY and CMD; the sealed variant; ENTRYPOINT with --; USER 0 / RUN / USER 65534; WORKDIR /data; mkdir and chown; named volume on a prepared and on a missing path; --tmpfs /scratch; --read-only --tmpfs /tmp; KCOS_EXEC with two directories; the agent-tools docker run line; --device with KCOS_DEV; examples/hello-http; the amd64 build refusal
- Writable places: a sweep of every directory finds only /tmp, /var/tmp and /dev/shm for nobody and for root; only /tmp and /var/tmp with --ipc none; none in the sealed image; only /work under the agent recipe, which also has no address but loopback, no route and no capability
- Sealed image: no shell or utility strings in the binary; started as sh, ls, cat or kcontaineros it is still init; same lockdown
- Stated limits are as the README says and no worse: rwx memory and exec-mapping a file work, and not on a noexec tmpfs; a device outside /dev is an ordinary file; a doubly mounted volume; root can chmod and touch but not change content; a shipped ld-musl runs a binary from /tmp; a Docker Desktop bind mount is readable, not writable, not runnable, and unreadable with an unnamed device; a sibling's /proc/PID/mem opens for the same user; scripts in /tmp run through sh only; the Landlock-missing warning; refusal to start without the filter (125); a failing landlock_add_rule grants nothing
- Shell: 158 experiments. Every supported row gives the same stdout and status as busybox sh; 27 control-flow and substitution constructs, 25 unsupported builtins and set options, 24 ${...} operators, 13 glob and tilde forms and 7 redirection forms are syntax errors with nothing run; a script's validity does not depend on variable values
- Utilities: the options the README names work; -Z is an error for all 16 that take options; -- ends options; mv refuses to cross filesystems; rm -r leaves symlink targets, refuses / . .., refuses 4200 levels, removes 4000, copes with 20 descriptors, reports once; kill rejects 0, -1 and wrapping PIDs; cp strips setuid, setgid and sticky and refuses self-copy; ps always, and ls, pwd and error messages on a terminal, replace non-printable bytes; 12 output paths exit 1 on /dev/full and on a closed descriptor
- Compared with Alpine: version 3.24.4, 13.6MB, layer 9.31MB, busybox 919 kB, 304 applets, musl 723 kB, 16 packages, CA certificates present, no tzdata, more than 50 times larger (57), stop 3201 ms with exit 137, 10202 ms with -t 10, 150 ms with --init
- Site: the page references no origin but assets.21no.de and the CSP allows no other; 404 handling is configured; the files in the README layout exist; the utility lists of README, page and llms.txt are identical and match --list
- The three documents do not disagree with each other in substance

## Not tested

- REPORT.md was not written: the Write tool refuses report files from a subagent and I did not work around it; this result and the logs under audit/claims/out and audit/claims/mutants carry its content
- First stage of the CA-certificates recipe (`apk add` needs the network); only the COPY stage was run, with stand-in files
- Alpine's architecture list (needs the registry)
- A kernel without Landlock or older than 5.19: only simulated with a Docker seccomp profile answering ENOSYS or EPERM
- Kubernetes, user namespaces, agent frameworks, bind mounts on a Linux host, Yama, Go and Zig binaries
- `make coverage` and the 99% line figure; `make site-preview`, `make site-deploy`, deployment on push to main
- The symlink-swap race that rm -r is built against (only static symlinks were tested)
- The limit about /proc or /sys mounted somewhere else
- Nested init started as a background job and brought forward with fg (the suite has checks; I did not repeat them)
- "Never allocates" beyond PID 1's memory map; absence of a stack protector
- The README's absolute start-up times (170 to 192 ms): the machine was busy with other audits and gave 331 to 404 ms
- Writing data to a named volume as nobody: the Docker VM's disk was full for non-root users during the audit ("No space left on device"), so that check creates an empty file instead
- A control for the full device sweep and for AF_VSOCK: block devices and hypervisor sockets were not opened without init; /dev/kmsg served as the control device
- Whether the m10 failure "at a prompt a misused builtin does not end the shell…" is caused by that mutant or is another flaky check (m10 is killed by three other checks either way)

## Findings

### C-01 — A device named in KCOS_DEV inside a subdirectory of /dev makes every other device in that subdirectory readable

- Severity: auditor **high**, reviewer **high**
- Reviewer's verdict: reproduced
- Where: src/lock.rs:136 (read is 0 unless unusual_devices) and src/lock.rs:268-272 (a named /dev/DIR/x accounts for the whole entry DIR)

The README says a device passed with --device has to be named, that "without the name the device is there but cannot be opened", and that nothing else in /dev opens "for reading or for writing". When KCOS_DEV names a device in a subdirectory (the README's own example is KCOS_DEV=/dev/fuse:/dev/net/tun), unusual_devices() treats the directory entry as accounted for. With nothing else unusual in /dev, the ruleset does not handle reading at all, so any unnamed device in that subdirectory opens for reading as far as its permissions allow. Writing stays refused. This was also observed with a host block device: the Docker VM's /dev/vda, passed unnamed next to a named sibling, opens read-only for root under init, and does not without the sibling. The operator must have passed the device with --device; what fails is the naming gate.

Reproduction:

```
docker run --rm --platform linux/arm64 --user 65534:65534 --device /dev/zero:/dev/net/tun --device /dev/zero:/dev/net/other -e KCOS_DEV=/dev/net/tun kcos-audit /bb/busybox sh -c '(true < /dev/net/other) 2>/dev/null; echo "read=$?"; (true >> /dev/net/other) 2>/dev/null; echo "write=$?"'
# block device, under init only, opened read-only and closed:
docker run --rm --platform linux/arm64 --user 0 --device /dev/vda:/dev/kcosdir/disk:r --device /dev/zero:/dev/kcosdir/named -e KCOS_DEV=/dev/kcosdir/named kcos-audit /bb/busybox sh -c '(true < /dev/kcosdir/disk) 2>/dev/null; echo "unnamed_disk_read_open=$?"'
# harness: audit/claims/claims.sh c2-lockdown (claim S010)
```

Expected: read=1 / write=1 / unnamed_disk_read_open=1

Observed: read=0 / write=1 / unnamed_disk_read_open=0 / (with neither device named, or without the named sibling, the read open is refused: read=1)

Reviewer: README 49-51, 97 and 369-370 say an unnamed device cannot be opened, for reading or writing. False for reading when any KCOS_DEV entry shares the subdirectory. New: the named entry need not exist; an entry init itself reports as ignored still switches read confinement off (src/lock.rs:268-272 with :136). Writing stays refused; the operator must have passed the device.

### C-02 — Mutant survives: process_vm_writev removed from the refusal list

- Severity: auditor **medium**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: test/suite.sh:171-179 (PROBES) against src/lock.rs:367-436 (DENIED)

The suite probes 11 calls (memfd_create, memfd_secret, process_vm_readv, io_uring_setup, bpf, userfaultfd, clone with CLONE_NEWUSER, vsock, clone3, 467, ptrace) and 6 through busybox tools. The other entries of DENIED have no check. The README names "reading or writing another process's memory" as refused. Two suite runs on this mutant showed only flaky failures (see C-09).

Reproduction:

```
audit/claims/mutants.sh m1    # diff in audit/claims/mutants/m1.diff:
--- a/src/lock.rs
+++ b/src/lock.rs
     270, // process_vm_readv
-    271, // process_vm_writev
     272, // kcmp
audit/claims/mutant-effect.sh m1
```

Expected: At least one check of the suite fails because of the change.

Observed: passed: 458 failed: 1 and passed: 456 failed: 3. The failures were "background commands ignore SIGINT and SIGQUIT" (a race, also 1 of 40 on the unmodified image) and two order-of-lines failures. On the mutant, as privileged root, `/bb/sc 271 999999 0 0 0 0 0` prints ret=0; on the original it prints errno=1.

Reviewer: Test gap, not a defect of the image. One call out of a list whose sibling (readv) is probed, so low rather than medium.

### C-03 — Mutant survives: /sys left writable for root

- Severity: auditor **medium**, reviewer **medium**
- Reviewer's verdict: reproduced
- Where: test/suite.sh:771-776 (KERNEL_FILES) against src/lock.rs:194

The README row "The kernel's files are out of reach for root" names /proc and /sys. The suite opens /proc/sys/kernel/core_pattern, /proc/sysrq-trigger and /dev/kmsg; no file of /sys.

Reproduction:

```
audit/claims/mutants.sh m3    # diff:
-            let kernel = root && matches!(name, b"proc" | b"sys");
+            let kernel = root && matches!(name, b"proc");
audit/claims/mutant-effect.sh m3
```

Expected: A check fails.

Observed: passed: 457 failed: 2, both flaky ("is PID 1 and the command is its child" got PID 6; "message queues cannot be created; shared memory can" had the same lines in another order). On the mutant, privileged root under init: "append-open of a /sys file: 0" for /sys/kernel/mm/transparent_hugepage/enabled; on the original it is 1.

Reviewer: README row names /sys and line 103 says `make test` checks each row. Test gap; the shipped code is correct.

### C-04 — Mutant survives: truncation not handled by the Landlock ruleset

- Severity: auditor **medium**, reviewer **medium**
- Reviewer's verdict: reproduced
- Where: test/suite.sh:130-170 (ATTACKS) against src/lock.rs:137

With FS_TRUNCATE left out of the ruleset, truncate(2) empties a file in a program directory. The README says nothing can be "written" there and that root "cannot change what is in them". No check truncates a file.

Reproduction:

```
audit/claims/mutants.sh m6    # diff:
-    let truncate = if abi >= 3 { FS_TRUNCATE } else { 0 };
+    let truncate = 0 * abi as u64;
audit/claims/mutant-effect.sh m6
```

Expected: A check fails.

Observed: passed: 458 failed: 1, an order-of-lines failure only. On the mutant, root under init: `chmod 666 /bb/probe; /bb/sc 45 s:/bb/probe 0; wc -c < /bb/probe` gives ret=0 and 0 bytes; on the original, errno=13 and 4798136 bytes.

Reviewer: Test gap for the 'nothing can be written in program directories' row.

### C-05 — Mutant survives: /dev/shm granted execute (only visible with an exec-mounted /dev/shm)

- Severity: auditor **medium**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: test/suite.sh (no execution from /dev/shm anywhere) against src/lock.rs:211

/dev/shm is the one writable place handled by its own rule. The suite never tries to run a program from it. Under Docker's default mount (noexec) the mutant behaves like the original; the difference shows with --tmpfs /dev/shm:exec, or any runtime that mounts it exec.

Reproduction:

```
audit/claims/mutants.sh m7    # diff:
-    allow(ruleset, b"/dev/shm", read | write);
+    allow(ruleset, b"/dev/shm", read | write | FS_EXECUTE);
audit/claims/mutant-effect.sh m7
```

Expected: A check fails.

Observed: passed: 458 failed: 1 (the PID flake only). On the mutant with `--user 0 --tmpfs /dev/shm:exec`: `cp /bb/sc /dev/shm/prog; /dev/shm/prog` prints "hello from prog args=[] uid=0"; on the original, "Permission denied".

Reviewer: Under Docker's default noexec mount the mutant is indistinguishable, so low. Matters for runtimes that mount /dev/shm exec.

### C-06 — Mutant survives with a fully green suite: files can be removed from program directories

- Severity: auditor **medium**, reviewer **medium**
- Reviewer's verdict: reproduced
- Where: test/suite.sh:130-170 against src/lock.rs:79 (FS_WRITE)

With LANDLOCK_ACCESS_FS_REMOVE_FILE dropped from the handled rights, root can delete programs from the image's program directories. The README says nothing can be "created, removed or written in those". The suite checks creation and moving in, never removal. This was the only one of the 17 suite runs with no failure at all.

Reproduction:

```
audit/claims/mutants.sh m8    # diff:
-const FS_WRITE: u64 = 1 << 1 | 0x1ff << 4;
+const FS_WRITE: u64 = 1 << 1 | 0x1fd << 4;
audit/claims/mutant-effect.sh m8
```

Expected: A check fails.

Observed: passed: 459 failed: 0. On the mutant, root under init: `chmod 777 /bb; rm /bb/probe` prints "removed"; on the original, "rm: can't remove '/bb/probe': Permission denied" and "still there".

Reviewer: Survival confirmed independently (the auditor had 459/0; I got the unrelated order flake of C-09). README row says 'created, removed or written'; removal is unchecked.

### C-07 — Three further mutants survive (KCOS_DEV symlink, namespace flags of clone, five calls the suite attacks with busybox)

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: test/suite.sh:130-170, 783-785 against src/lock.rs:216, 361, 367-436

Run beyond the eight asked for. m11: a symbolic link named in KCOS_DEV is accepted; only the warning is lost, and a rule on a link grants nothing. m12: CLONE_NEW_ANY reduced to CLONE_NEWUSER; no behavioural difference was seen because the kernel refuses the other namespaces for lack of capabilities. m13: mount, chroot, sethostname, clock_settime and settimeofday removed from DENIED; the suite's attacks with mount, chroot, hostname and date print the same messages because the capability drop refuses them too. For these calls the suite cannot tell whether the filter works.

Reproduction:

```
audit/claims/mutants.sh m11 m12 m13   # diffs in audit/claims/mutants/m11.diff, m12.diff, m13.diff
audit/claims/mutant-effect.sh m11 m12 m13
```

Expected: Each mutant fails a check.

Observed: m11, m12 and m13 each: passed: 458 failed: 1, an order-of-lines failure only. Effects: m11 loses the warning "KCOS_DEV: /dev/stdin is not a device in /dev"; m12 still gives errno=1 for clone(CLONE_NEWNET) and clone(CLONE_NEWNS); m13 gives mount errno=14, chroot errno=14, clock_settime errno=14 (the kernel is reached) where the original gives errno=1.

Reviewer: m13 is the real gap: for calls the capability drop also refuses, the suite's busybox attacks cannot tell whether the filter works. m12 has no observable effect under init, m11 loses a warning only.

### C-08 — The suite sets the Docker VM's clock to 2001-01-01 on every run

- Severity: auditor **medium**, reviewer **medium**
- Reviewer's verdict: reproduced
- Where: test/suite.sh:135 (`date -s 2001-01-01` in ATTACKS) run by the control at test/suite.sh:168-170

The control "without init the same container allows them" runs the attack list as privileged root without any filter and expects rc=0 for every line, including `date -s 2001-01-01`. The clock is not namespaced, so the wall clock of the whole Docker VM, and of every container on it, jumps to 2001 until Docker Desktop resynchronises. AGENTS.md requires that "nothing on the machine running the tests may change". During the jump, TLS validation, build timestamps and anything else reading the wall clock in any container is wrong.

Reproduction:

```
audit/claims/build.sh   # only if kcos-audit is missing its helper; clockwatch uses kcos-audit
audit/claims/clockwatch.sh 300 > /tmp/clock.log &   # samples `date` in a container twice a second
IMG=kcos-wip test/e2e.sh
cat /tmp/clock.log
```

Expected: No jump of the clock.

Observed: One jump per suite run, 8 in 20 minutes (audit/claims/out/clock.log), for example: / jump: 1795339326 -> 978307200 (2026-11-22 09:22:06 -> 2001-01-01 00:00:00) / jump: 978307221 -> 1795339348 (2001-01-01 00:00:21 -> 2026-11-22 09:22:28) / Durations: 11 to 27 seconds.

Reviewer: Every container on the daemon saw 2001 for 17 s. Breaks the AGENTS.md rule that nothing on the test machine may change. Defect of the suite, not of the image.

### C-09 — `make test` is not reliably green: the unmodified sources failed one check in 3 of 3 runs

- Severity: auditor **medium**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: test/e2e.sh:50-57 (expect merges stdout and stderr of `docker run` with 2>&1 on the host); test/suite.sh:53, 651, 699-701, 780-781, 788-789, 186-191, 704-707

Three kinds of flaky check. (1) Order of stdout and stderr: `expect` merges two streams that Docker delivers separately, so a warning on stderr and output on stdout arrive in either order; expected and actual hold the same lines. (2) A pinned PID: "is PID 1 and the command is its child" expects PID 7 and sometimes gets 6; `docker run --rm kcontaineros ps` gave 6 in 1 of 6 runs. (3) A race: "background commands ignore SIGINT and SIGQUIT" reads /proc/$!/status before the child has set its dispositions. Release step 2 asks for a green `make test`, and real regressions hide in this noise. The machine was loaded by other audits, which makes races more likely but does not create them.

Reproduction:

```
IMG=kcos-wip test/e2e.sh   # repeat; or: audit/claims/mutants.sh m0 m0b m0c; python3 audit/claims/verdicts.py
# the race alone:
docker run --rm --platform linux/arm64 --entrypoint /bb/busybox kcos-audit sh -c 'i=0; while [ $i -lt 40 ]; do /bin/sh -c "sleep 1 & /bb/busybox grep SigIgn /proc/\$!/status"; i=$((i+1)); done | /bb/busybox sort | /bb/busybox uniq -c'
```

Expected: passed: 459 failed: 0 on unmodified sources, every time.

Observed: m0: failed 1 ("a shell that cannot fork says so and goes on", lines in another order); m0b and m0c: failed 1 ("is PID 1 and the command is its child", PID 6). Over 17 runs, 15 had at least one such failure. Counts: "a shell that cannot fork…" 5 runs; the PID check 5; "a device passed in cannot be opened…" 3; "a program directory below one that is missing…" 2; "KCOS_EXEC names further directories…" 1; "message queues cannot be created…" 1; "background commands ignore SIGINT and SIGQUIT" 2 (and SigIgn 0 in 1 of 40 on the unmodified image).

Reviewer: All three kinds are races in the checks, not in the image. I rate it low: test reliability, though it hides regressions and makes release step 2 unreachable on a loaded host. The machine was loaded during my runs too.

### C-10 — README: "The top-level directory of an ignored entry is not writable all the same" is false for entries with a trailing slash, `.` or `..`

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: README.md:47-48 and docs/index.html ("Before you build on it"); src/lock.rs:188-190 (holds_programs uses absolute_dirs, which has already dropped these entries)

An entry rejected as "not a plain absolute path" is dropped before the top-level directories are classified, so its top-level directory stays writable. The sentence holds for entries that pass the syntax test but cannot be used (missing directory). Nothing becomes executable; only the documented restriction is absent.

Reproduction:

```
printf 'FROM kcontaineros\nWORKDIR /app/data\nWORKDIR /\n' | docker build -q --platform linux/arm64 -t kcos-audit-claims-r-app - 
docker run --rm --platform linux/arm64 -e KCOS_EXEC=/app/bin/ kcos-audit-claims-r-app sh -c 'echo x > /app/data/f; echo rc=$?'
docker run --rm --platform linux/arm64 -e KCOS_EXEC=/app/nonexistent kcos-audit-claims-r-app sh -c 'echo x > /app/data/f; echo rc=$?'
docker rmi kcos-audit-claims-r-app
# harness: audit/claims/claims.sh c4-recipes (claim U014)
```

Expected: Both: "sh: /app/data/f: permission denied" and rc=1, after the warning.

Observed: KCOS_EXEC=/app/bin/ (also /app/./bin and /app/../app/bin): "kcontaineros: warning: KCOS_EXEC: /app/bin/ is not a plain absolute path: ignored", then rc=0 and the file is written. KCOS_EXEC=/app/nonexistent: permission denied, as documented.

Reviewer: README 45-48 lists the trailing slash, `.` and `..` as ignored entries and then says the top-level directory of an ignored entry is not writable. False for exactly those. Nothing becomes executable; a documented restriction is absent.

### C-11 — `test` is not a syntax error: a script using it runs on and takes the failure branch

- Severity: auditor **low**, reviewer **info**
- Reviewer's verdict: reproduced, already documented
- Where: README.md:472 (features table), README.md Limits; src/sh.rs (no `test` in the refused names)

`[` is refused before the script starts (as a glob character). `test` is looked up as a command when reached, fails with 127, and the script continues. `test COND || cmd` therefore always runs cmd, and `test COND && cmd` never does. The README says there is no such command, which is true, but its rule that anything outside the subset is "a syntax error found before the first command runs, not something run as something else" does not hold for the most common spelling of a condition. `printf` and `time` behave the same way.

Reproduction:

```
docker run --rm --platform linux/arm64 kcontaineros sh -c 'MODE=prod; test "$MODE" = prod || echo DESTRUCTIVE-BRANCH-RAN; echo "script went on, rc=$?"'
```

Expected: By the project's rule: a syntax error, exit 2, nothing run. (POSIX: only "script went on, rc=0".)

Observed: sh: test: not found / DESTRUCTIVE-BRANCH-RAN / script went on, rc=0

Reviewer: Happens as described, but the README says there is no such command, and a missing command giving 127 with a message is loud and is not 'run as something else'. Refusing `test`/`printf` in check() would be a sensible hardening, since `test X || cmd` always runs cmd.

### C-12 — Suite checks that prove less than their name says

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: test/suite.sh lines 249, 251, 254, 257, 263, 657, 694, 697, 732, 749, 761, 763 (grep-only); 206; 788-789; 790-793; 619, 645, 738; test/e2e.sh:10-11

(1) Twelve terminal checks keep only a few whole lines of the session with grep and ignore everything else, while e2e.sh states "Every check compares complete output and the exit status". (2) "nobody cannot change the image" (206) prints the same three refusals without init, because file permissions refuse the writes; it says nothing about the lockdown. (3) "message queues cannot be created; shared memory can" (788) has no control and tests a path open; mq_open(2) under init does create the queue object, which then cannot be opened. (4) "run as the README has it for agent tools, /work is the only place to write" (790) tries four paths on the full image, not the sealed one. (5) Line 619 judges `${#VAR}`, `${VAR%x}` and `${}` by exit status 2 alone with stderr discarded; 645 likewise; 738 ("ls -l survives an entry that vanishes") sends the output to /dev/null. (6) The no_new_privs row has no check with a setuid binary or file capabilities.

Reproduction:

```
# (2) the check's command without init:
docker run --rm --platform linux/arm64 --user 65534:65534 --entrypoint /bb/busybox kcos-audit sh -c 'exec /bin/sh -c "$1" 2>&1' m 'echo x > /bin/kcontaineros; echo x >> /etc/passwd; echo x > /usr/local/bin/x; true'
# (3) audit/claims/build.sh, then:
docker run --rm --platform linux/arm64 --user 65534:65534 kcos-audit-claims-img /bb/busybox sh -c '/bb/sc mq kcosq; /bb/busybox ls -l /dev/mqueue'
```

Expected: (2) Without init the writes succeed, if the check is about init. (3) No queue is created.

Observed: (2) The same output as under init: "sh: /bin/kcontaineros: permission denied", "sh: /etc/passwd: permission denied", "sh: /usr/local/bin/x: permission denied", rc 0. (3) "mq_open errno=13" and then "-rw------- 1 nobody nobody 80 ... kcosq": the queue object exists. Without init the same helper stores and reads back a message.

Reviewer: Test-quality findings, all accurate. README 526 hedges with 'wherever they can'; test/e2e.sh:10 says 'Every check'. The mq_open result (the queue object is created under init but cannot then be opened) is a small real oddity inside this finding.

### C-13 — "Forwards every signal": SIGCHLD is not forwarded

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced, not a defect
- Where: README.md:14 and 455, docs/index.html (/sbin/init card); src/init.rs:108-111

Init uses SIGCHLD for its own reaping and never passes it on. Every other standard signal except KILL and STOP is forwarded, and real-time signals 34 and 64 are too. The documents say "every signal" and "every catchable signal".

Reproduction:

```
docker run -d --platform linux/arm64 --name kcos-audit-claims-c kcos-audit /bb/busybox sh -c 'for n in $(/bb/busybox seq 1 31); do case $n in 9|19) ;; *) trap "echo got-$n" $n;; esac; done; echo ready; /bb/busybox sleep 1000 & while :; do wait; done'; sleep 1.5
for n in $(seq 1 31); do case $n in 9|19) ;; *) docker kill -s $n kcos-audit-claims-c >/dev/null; sleep 0.15;; esac; done
docker logs kcos-audit-claims-c | tr '\n' ' '; docker rm -f kcos-audit-claims-c
```

Expected: ready got-1 ... got-17 ... got-31 (29 signals)

Observed: ready got-1 got-2 ... got-16 got-18 got-20 ... got-31 (no got-17)

Reviewer: An init has to keep SIGCHLD for reaping; forwarding it would be wrong, and no init does. 'Every signal' in README 14 and 455 is loose by one signal nobody sends to a container: a wording nit at most.

### C-14 — /dev/termination-log is on the device allowlist and no document lists it

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: src/lock.rs:76 and 272; README.md:49-51 and 97; docs/llms.txt

The allowlist the documents give ends with "Nothing else". The code also allows /dev/termination-log (for Kubernetes) and treats it as a usual entry. Whatever is at that path opens unnamed, a device node included.

Reproduction:

```
docker run --rm --platform linux/arm64 --user 65534:65534 --device /dev/zero:/dev/termination-log kcos-audit /bb/busybox sh -c '(true < /dev/termination-log) 2>/dev/null; echo "read=$?"; (true >> /dev/termination-log) 2>/dev/null; echo "write=$?"'
```

Expected: read=1 / write=1

Observed: read=0 / write=0

Reviewer: Undocumented allowlist entry; the documents end the list with 'Nothing else'. Needs an operator to map a device to exactly that name, so info.

### C-15 — `ls -a` leaves out `.` and `..`; `set` without arguments prints nothing

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/applets.rs (ls), src/sh.rs (set)

Two places where a supported command silently differs from POSIX, against the project's rule "correct or loud, never silently different". `ls -a` behaves like `ls -A`. `set` with no arguments exits 0 with no output where POSIX prints the variables.

Reproduction:

```
docker run --rm --platform linux/arm64 -w /tmp --entrypoint /bb/busybox kcos-audit sh -c '/bb/busybox mkdir d; cd d; : > .h; : > v; /bin/ls -a'
docker run --rm --platform linux/arm64 kcontaineros sh -c 'A=1; set; echo "rc=$?"'
```

Expected: . / .. / .h / v / and, for set, the variables (or an error naming the unsupported form)

Observed: .h / v / and / rc=0

Reviewer: Neither difference is mentioned in the README (set is documented as accepting -e, -x and -- ARGS; the bare form is accepted silently). Minor silent deviations from POSIX against the project's 'correct or loud' rule.

