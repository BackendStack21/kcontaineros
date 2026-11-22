# Track: escape-root

What the auditor of this track reported, unedited apart from layout, and what the
independent reviewer made of each finding. The state of the tree is that of 0.2.0
(commit `deffcb4`); what was done about each finding is in [../README.md](../README.md).

## What was exercised

Track escape-root: root under init in a privileged container (seccomp and AppArmor unconfined), kContainerOS 0.2.0 at deffcb4, kernel 7.0.14-linuxkit, Landlock ABI 8. No escape and no privilege gain was found; the control without init succeeded for every attempt that held. Four findings (one medium, three low) and one info.

REPORT.md was NOT written: the harness refused the Write call ("Subagents should return findings as text, not write report files"). Its content is this result; the raw run output is in audit/escape-root/results/.

Method: read lock.rs, init.rs and the README Security section; checked the seccomp program by hand (jump offsets, the 71 denied numbers against the aarch64 table); then ran a static C helper (esc.c, placed in /aud via KCOS_EXEC) under init and without init. Control runs use arguments that cannot take effect (bad pointers, nonexistent paths), append-open only, and never open block devices, /dev/vsock or AF_VSOCK.

Exercised, each under init and in the control unless noted:
- 76 system-call probes (63 on the denied list, plus clone3, personality in 5 shapes, numbers 467 and 600, both probe prctls) and 10 clone/unshare namespace attempts.
- 18 capability/prctl checks and 14 identity/privilege calls.
- socket() for families 0-46 x 4 types and netlink protocols 0-22 (AF_VSOCK under init only).
- A file-capability program and a setuid-root program as root and as uid 1000; root without CAP_SETPCAP.
- 11 ways of starting a copied program from each of /tmp, /dev/shm and /var/tmp, plus /proc/self/map_files of shared anonymous memory and SysV shm, a PT_INTERP and a #! interpreter in /tmp, a second allow-all seccomp filter, and a second allow-exec Landlock domain.
- 28 operations against each of 4 program directories (/aud, /bin, /usr/bin, /bb).
- Append-open of every regular file in /proc (2571) and /sys (14478) under init; 15 sample files in the control.
- Read-open and append-open of all 348 /dev nodes under init (350 with -t).
- Core dump with a program directory as working directory.
- PID 1: signals, pidfd, ptrace, process_vm_readv, setns, prlimit64, affinity, nice, I/O priority, 19 read-opens and 10 append-opens of /proc/1/*.
- Inherited descriptors, environment, signal mask and limits; docker exec of the kContainerOS shell and of busybox.

Environment: the Docker VM disk was full (0 bytes available), so the compiler stage uses rust:1-alpine, which was already present. The image kcos-audit-escape-root-img was removed afterwards and no container is left; build.sh or run-all.sh rebuilds it.

## What held

- Capabilities: CapInh/Prm/Eff/Bnd/Amb are all zero for root under init with --privileged; NoNewPrivs 1, Seccomp 2. capset(all), capset(inheritable), PR_CAP_AMBIENT_RAISE, PR_SET_SECUREBITS, PR_SET_NO_NEW_PRIVS 0, PR_SET_SECCOMP 0 and PR_SET_MM are all refused (control: capset and securebits succeed).
- Root started with every capability except CAP_SETPCAP (not --privileged, which ignores --cap-drop): the bounding set keeps 40 capabilities, but the process sets are zero, capset is refused, and /proc/sys stays unwritable.
- File capabilities and setuid as uid 1000 under init: CapEff stays 0 and the uid stays 1000 (control: full capabilities, euid 0).
- Filter: all 63 probed calls on the denied list return EPERM under init and reach the kernel in the control. clone3 returns ENOSYS, syscalls 467 and 600 return ENOSYS, and personality(ADDR_NO_RANDOMIZE) is refused, also with high bits set in the argument.
- Namespaces: clone() with each of NEWNS/CGROUP/UTS/IPC/USER/PID/NET (also with the upper 32 bits set), unshare(NEWUSER) and unshare(NEWTIME) are refused; all succeed in the control.
- The filter and the Landlock domain cannot be loosened: after a second allow-all seccomp filter, memfd_create and unshare are still EPERM; after stacking a Landlock domain that allows execute on /, a copy in /tmp still cannot be executed.
- Run-or-write: a copied program in /tmp, /dev/shm or /var/tmp cannot be started by execve, execveat on a descriptor or an O_PATH descriptor, /proc/self/fd/N, /proc/self/root/..., after unlink, or from an O_TMPFILE file (all EACCES). A hard link out of a program directory gives EXDEV. /proc/self/map_files of shared anonymous memory and SysV shm gives EPERM. The control runs the program in every case from /tmp and via map_files.
- A program in a program directory whose PT_INTERP is in /tmp, and a script whose #! interpreter is in /tmp, both fail with Permission denied under init and run in the control.
- Program directories (/aud, /bin, /usr/bin, /bb): create, mkdir, symlink, mkfifo, O_TMPFILE, unix socket bind, rename in/out/within/exchange, link, open for write, O_TRUNC, truncate, unlink and rmdir all give EACCES; the control succeeds. security.capability and trusted.* xattrs and the immutable flag give EPERM.
- /proc and /sys for root: append-open of all 2571 regular files tried in /proc and all 14478 in /sys gives EACCES, also through /proc/self/root, /proc/thread-self/root, /proc/self/cwd and /dev/fd/../..; mkdir in /sys/fs/cgroup is refused. The control opens 13 of 15 sample files (the other two do not exist on this host).
- /dev under --privileged: of 348 nodes, only null, zero, full, random, urandom and pts/ptmx open (plus console, tty and pts/0, the container's own pty, with -t). /dev/mem, /dev/kmsg, /dev/vda, /dev/vsock and /dev/fuse are refused for read and append; the control opens /dev/kmsg and /dev/fuse.
- Core dump: with core_pattern 'core' and a program directory as working directory, no core file is created under init (the control creates /aud/core); in /tmp it is created.
- PID 1 is opaque: /proc/1/environ, maps, smaps, mem, auxv, pagemap, fdinfo, root, cwd and exe are refused; stack, syscall and io fail on read; fd links cannot be read; /proc/1/stat shows zeros for the address fields. pidfd_getfd, ptrace(SEIZE), process_vm_readv and setns on PID 1 give EPERM. kill(1, KILL/STOP) has no effect.
- Signals sent to PID 1 from inside (USR1, TERM) are forwarded to the command only; init has no handlers (SigCgt 0).
- Inheritance: the command gets descriptors 0, 1 and 2 only, the image's environment with nothing added by init, an empty signal mask and nothing ignored.
- Raw and packet sockets (AF_INET SOCK_RAW, AF_PACKET, AF_KEY, AF_XDP) give EPERM; AF_VSOCK gives EPERM also with high bits set in the family argument.
- setuid, setgid, setgroups, mknod of a character device, chown to another user, negative nice, SCHED_FIFO, SCHED_DEADLINE and raising a hard rlimit are refused under init and succeed in the control.
- docker exec behaves as the README says: the kContainerOS shell gets no_new_privs and the filter but keeps all capabilities and is not under Landlock; busybox gets nothing. The workload under init cannot read environ, mem or root of a docker exec process, nor open its mem for writing.
- Consistent with the README, so not findings: root can chmod image files outside program directories and then write them (/etc/passwd, new files in /etc); mmap(PROT_EXEC) of a file in /tmp works (refused on the noexec /dev/shm); root can chmod and utimes files in program directories.

## Not tested

- REPORT.md was not written: the harness blocked the Write call for report files. Its content is in this result.
- Linux hosts other than Docker Desktop's VM, kernels other than 7.0.14-linuxkit, kernels without Landlock, user-namespace remapping, rootless Docker, Kubernetes.
- --pid=host, --net=host, --ipc=host, bind mounts, volumes, --device and KCOS_DEV: outside the stated configuration.
- Controls for AF_VSOCK, /dev/vsock and block devices (forbidden by the audit rules): only the refusal under init was observed, with the device nodes listed in the control.
- Control for creating a cgroup with mkdir in /sys/fs/cgroup (it would change /sys): refusal under init only.
- PTRACE_TRACEME and tracing a live child (audit rules): ptrace was probed only with PTRACE_SEIZE on PID 1 and on a nonexistent PID.
- Calls the host kernel does not implement returned ENOSYS in the control (userfaultfd, kexec_load, kexec_file_load, delete_module, mbind, set_mempolicy, migrate_pages, move_pages, set_mempolicy_home_node, lookup_dcookie, nfsservctl); for these the control shows only that the filter answers first.
- binfmt_misc: not mounted in the container (the directory is empty), so there was nothing to attack.
- Terminal attacks (TIOCSTI into a docker exec -it session; legacy_tiocsti is 1 on this host), kernel bugs, side channels, network attacks on other containers.
- The sealed image: it has nothing a workload could run.
- Whether /proc/timer_list names other containers' processes: on this kernel it prints no process names.
- The four findings were not re-run after the image was removed. The saved results come from the runs described; 01-syscalls.sh was run twice with the same outcome apart from the corrected CAP_SETPCAP section.
- The root cause of the mq_open failure was not confirmed in kernel source; only the behaviour was observed.
- run-all.sh itself was not executed end to end; each script it calls was run individually.

## Findings

### ESCROOT-1 — Root under init still reads the host kernel's root-only files in a privileged container

- Severity: auditor **medium**, reviewer **medium**
- Reviewer's verdict: reproduced
- Where: src/lock.rs:191-195 (confine_files: /proc and /sys get the read right for root); README.md Security table, rows 'No capabilities' and 'The kernel's files are out of reach for root'

Landlock removes only the write rights on /proc and /sys for root; the read right is granted on both. Root owns the kernel's 0400 files, and --privileged removes Docker's masking, so root under init reads /proc/slabinfo (kernel heap state), /proc/vmallocinfo, /proc/timer_list, /proc/kpagecount and /proc/kpageflags (physical page state), and sees in /proc/keys the session keyrings of other containers, named by container ID (11 on the audit host). uid 1000 under the same init reads none of these. /proc/kcore, /proc/kmsg and kallsyms addresses stay hidden because they need capabilities. The README says root 'is an ordinary user to the kernel, even under --privileged' and heads the row 'The kernel's files are out of reach for root'; only writing is stopped, and the limits section does not mention reads.

Reproduction:

```
bash audit/escape-root/build.sh && bash audit/escape-root/05-kernel-reads.sh
# or by hand:
docker run --rm --platform linux/arm64 --privileged --security-opt seccomp=unconfined --security-opt apparmor=unconfined kcos-audit /bb/busybox sh -c '/bb/busybox head -3 /proc/slabinfo; /bb/busybox wc -l /proc/vmallocinfo /proc/timer_list; /bb/busybox grep -c _ses /proc/keys; /bb/busybox od -An -tx8 -j 8388608 -N 32 /proc/kpageflags'
# ordinary user for comparison: add --user 1000:1000
```

Expected: Root under init gets what an ordinary user gets (Permission denied on the 0400 files, only its own keys in /proc/keys), as uid 1000 does: 'head: /proc/slabinfo: Permission denied', 0 bytes readable from slabinfo, vmallocinfo, timer_list and kpagecount.

Observed: As root under init: '/proc/slabinfo: mode 400, 23371 of the first 65536 bytes readable' ('slabinfo - version: 2.1', 'ext4_groupinfo_4k 480 535 152 ...'); /proc/vmallocinfo 5890 lines; /proc/timer_list 994 lines; /proc/kpagecount 65536 of 65536 bytes; /proc/kpageflags returns page flags (0000000000008080 0000000000010080 ...); /proc/keys 1273 bytes with 11 '_ses.<container id>' keyrings (uid 1000 sees 136 bytes, its own only).

Reviewer: Real, but it is a documentation defect rather than a hole in the lockdown: init neither adds nor removes read access, the reads follow from uid 0 owning the files (a plain Docker root with all caps dropped reads the same unmasked files). No escape or privilege gain. README row body is accurate ('cannot open them for writing') but the row title 'The kernel's files are out of reach for root' and 'Root in the container is an ordinary user to the kernel, even under --privileged' overstate, and the limits section never says root still reads root-owned kernel files (under --privileged including timer_list and other containers' keyring names). Medium as misleading security documentation; agree with the auditor.

### ESCROOT-2 — Any process under init can change PID 1's limits and scheduling and have the kernel kill it (container exits 137)

- Severity: auditor **low**, reviewer **info**
- Reviewer's verdict: reproduced, not a defect
- Where: src/lock.rs DENIED list / install_filter (prlimit64 261, setpriority 140, sched_setaffinity 122, ioprio_set 30 are allowed for any target PID); src/init.rs main loop

Init runs with the same UID as the command, and the filter does not restrict calls that act on another PID by UID match. From the command, prlimit64(1, ...) changes init's resource limits, setpriority(1) its nice value, ioprio_set its I/O class, sched_setaffinity its CPU mask. With RLIMIT_CPU set to 1 second on PID 1 and a flood of signals for init to forward, the kernel kills PID 1 with SIGKILL and the container ends with status 137, without the command's exit status. Signals sent directly (kill -KILL 1, kill -STOP 1) have no effect, so this is the one way a process inside can kill init. It gives no privilege; it lets any same-UID process (not only the main command) end the container and falsify its exit status.

Reproduction:

```
bash audit/escape-root/build.sh
P='--platform linux/arm64 --privileged --security-opt seccomp=unconfined --security-opt apparmor=unconfined'
docker run --rm $P kcos-audit-escape-root-img /aud/esc pid1 | grep -A2 -E 'prlimit64|setpriority|ioprio'
docker run --rm $P kcos-audit-escape-root-img /bb/busybox sh -c "trap '' URG; /aud/esc cpukill; echo command finished normally"; echo "exit status: $?"
# (both are in audit/escape-root/03-init.sh)
```

Expected: PID 1's state cannot be changed from inside ('change init's own state' is a goal the lockdown should refuse); the second command prints 'still here after N signals to PID 1', 'command finished normally' and exits 0.

Observed: 'prlimit64(1,NOFILE,set soft=7): ok(0)' with 'pid 1 NOFILE after: 7/1048576'; 'setpriority(1, +1): ok(0)' with 'pid 1 nice: before 0, after 1'; 'ioprio_set(pid 1, idle class): ok(0)'; 'sched_setaffinity(1,same mask): ok(0)'. Second command prints only 'prlimit64(1, RLIMIT_CPU, 1s): ok(0)' and the container exits with status 137.

Reviewer: The behaviour is exactly as reported, also for the default user. I do not count it as a defect: the README claims PID 1 is opaque (not dumpable/readable), not that same-UID processes cannot end it, and the outcome (container ends with 137 instead of the command's status) is already available to any same-UID process by SIGKILLing the main command, as my equivalence run shows. No privilege, no loosening of restrictions. Limiting prlimit64 to pid 0/self in the filter would be cheap hardening, nothing more.

### ESCROOT-3 — Root can set extended attributes on files in program directories, including /bin/kcontaineros

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/lock.rs confine_files (Landlock does not mediate xattrs); README.md 'Root can still change the permissions and timestamps of files it owns, in program directories too. It cannot change what is in them.'

Landlock has no right for extended attributes, and root owns the image's files. setxattr of a user.* attribute succeeds directly on files that are owner-writable by mode (/aud, /bb) and, after chmod u+w, on the image's own binary. The README lists only permissions and timestamps as changeable and says nothing can be 'created, removed or written' in program directories. File contents were not changed (open for write gives EACCES/ETXTBSY), and security.capability and trusted.* are refused, so no privilege follows; data can be attached to program files and the documented list of what root can change is incomplete.

Reproduction:

```
docker run --rm --platform linux/arm64 --privileged --security-opt seccomp=unconfined --security-opt apparmor=unconfined kcos-audit /bb/busybox sh -c '/bb/busybox chmod u+w /bin/kcontaineros; /bb/busybox setfattr -n user.kcos -v planted /bin/kcontaineros; echo setfattr exit $?; /bb/busybox getfattr -n user.kcos /bin/kcontaineros; /bb/busybox setfattr -n user.kcos -v planted /bb/busybox; echo exit $?'
# also: bash audit/escape-root/04-extras.sh (section 'extended attributes')
```

Expected: setfattr fails: nothing can be written to a file in a program directory.

Observed: 'setfattr exit 0', then '# file: /bin/kcontaineros' / 'user.kcos="planted"'. The helper shows 'setxattr(victim, user.kcos): ok(0)' and 'removexattr(victim, user.kcos): ok(0)' for /aud/interp-in-tmp and /bb/busybox without any chmod.

Reviewer: Root only; file contents unchanged, nothing persists beyond the container's own overlay layer, privileged xattr namespaces refused. No security consequence found. The defect is that the README's list of what root can still change on program files ('permissions and timestamps') is incomplete and 'nothing can be created, removed or written in those' is not literally true of metadata. Low, documentation.

### ESCROOT-4 — POSIX message queues cannot be opened under init (mq_open returns EACCES)

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/lock.rs confine_files (ruleset handles write rights; the mqueue filesystem is reached by mq_open on a mount no rule covers)

mq_open(name, O_CREAT|O_RDWR, 0600) fails with EACCES for every process under init: root in a privileged container, root with default options, and the default user 65534 with default options. The same call succeeds without init. Probable cause (not verified in kernel source): Landlock checks the open of the queue on the mqueue mount internal to the IPC namespace, which no path rule can cover. SysV shm, msg and sem work. The README does not mention it.

Reproduction:

```
bash audit/escape-root/build.sh
docker run --rm --platform linux/arm64 --user 65534:65534 kcos-audit-escape-root-img /aud/esc ipc | grep mq_open
docker run --rm --platform linux/arm64 --user 65534:65534 --entrypoint /aud/esc kcos-audit-escape-root-img ipc | grep mq_open
```

Expected: mq_open: ok(3) in both runs.

Observed: Under init: 'mq_open: errno 13 (Permission denied)' (same for root, privileged or not). Control: 'mq_open: ok(3)'.

Reviewer: Functional bug that fails closed; undocumented. The cause (Landlock on the internal mqueue mount) was not verified by me either.

### ESCROOT-5 — As root under init, a program carrying file capabilities with the effective bit cannot be started at all

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: src/lock.rs drop_capabilities (empty bounding set); README.md row 'No privilege gain'

The README says file capabilities 'grant nothing'. For root, whose bounding set init empties, the kernel refuses to execute a file whose security.capability has the effective bit and permitted capabilities outside the bounding set: execve returns EPERM. As uid 1000 the same file runs, without capabilities. A tool installed with setcap ...+ep (ping in many images) therefore fails for root instead of running unprivileged. Fail-closed, not a weakness.

Reproduction:

```
bash audit/escape-root/build.sh
docker run --rm --platform linux/arm64 --privileged kcos-audit-escape-root-img /aud/esc-fcaps caps
docker run --rm --platform linux/arm64 --privileged --user 1000:1000 kcos-audit-escape-root-img /aud/esc-fcaps caps | grep CapEff
```

Expected: The program runs with no capabilities in both cases.

Observed: As root: 'kcontaineros: /aud/esc-fcaps: operation not permitted'. As uid 1000: 'CapEff: 0000000000000000'.

Reviewer: Kernel behaviour with an emptied bounding set and an effective-bit file capability; fails closed and the README claim 'file capabilities grant nothing' holds. Only an undocumented compatibility note (a setcap +ep tool is refused for root rather than run unprivileged). Not a weakness.

