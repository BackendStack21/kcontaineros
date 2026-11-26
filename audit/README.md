# Security audit of kContainerOS 0.2.0

An end-to-end audit of the release tagged `v0.2.0` (commit `deffcb4`), run on
22 November 2026, and what was done about what it found. The fixes are in
1.0.0. A summary is in [`AUDIT.md`](../AUDIT.md).

Everything here can be run again: each track left its harness in its
directory, and the checks that came out of the audit are in `test/suite.sh`.

## Who did it, and what that is worth

The audit was designed, run and written up by an AI model (Claude), which
also wrote most of the code under audit. Nobody outside the project has
reviewed the image. The design tries to make up for that in three ways,
and none of them is the same as a second party:

- **Auditors that start from nothing.** Each track was given to an agent
  with no knowledge of how the code had been written or reviewed, told to
  trust neither the comments nor the README nor the test suite, and to
  count only what a real container does.
- **Evidence that does not rest on judgement.** Where a property can be
  established mechanically, it was: the filter was read back from the
  kernel and interpreted for every system call number; the shell was
  compared with another shell on generated scripts; the test suite was
  run against deliberately broken copies of the lockdown.
- **A finding counts when someone else reproduces it.** Every finding of
  every track went to a second agent whose task was to refute it in fresh
  containers, with the control run without init where the lockdown was
  concerned. The table below gives that reviewer's severity, not the
  auditor's.

What this cannot rule out: a mistake that every agent makes in the same
way, a kernel behaviour none of them knew to try, and anything that only
shows on a host other than the one used (Docker Desktop on macOS arm64,
kernel 7.0.14-linuxkit, Landlock ABI 8). It was one kernel, one runtime,
one day.

## Tracks

| Track | Question | Method |
| --- | --- | --- |
| [seccomp](seccomp/RESULT.md) | Is the installed filter the intended one, with no way round it? | The program was read from the kernel with `PTRACE_SECCOMP_GET_FILTER` (12 copies, 11 processes), interpreted for every number 0..1100 and for the argument clauses over boundary values, checked for jump and accumulator errors, and compared with real calls under init and without it. |
| [landlock](landlock/RESULT.md) | Who can do what, where? | An access matrix of paths, operations, users and mount types, under init and without; attacks on how the rules are built (links, odd `KCOS_EXEC` and `KCOS_DEV` values, devices under other names). |
| [escape-root](escape-root/RESULT.md) | Can root in a `--privileged` container with Docker's protections off get past the lockdown? | A hostile workload with its own static helpers: capabilities, kernel files, cgroups, devices, IPC, mount and namespace interfaces, PID 1 itself. |
| [escape-user](escape-user/RESULT.md) | Can the default user, in the ways the image is really run? | 17 configurations including the agent recipe: run what was written at run time, write and read where it should not, outlive init, forge its messages, steer it through the environment. |
| [init](init/RESULT.md) | Does PID 1 stay correct under stress? | Every way a command can end, every signal, floods, orphans by the thousand, leftovers that resist, fork failure, closed descriptors; the source read line by line. |
| [shell](shell/RESULT.md) | Is the shell correct or loud? | Generated scripts in the documented subset run through this shell and busybox `sh` and compared; mutated and random input for crashes and hangs; interactive sessions. |
| [utils](utils/RESULT.md) | Are the utilities safe on hostile trees? | Comparison with busybox on generated trees; a race harness that swaps directories for links under `rm`, `cp`, `mv`, `mkdir -p`; terminal output; option and number parsing. |
| [memory](memory/RESULT.md) | Where Rust's guarantees stop | Every `unsafe` block and kernel structure checked against its contract; the entry code and allocator; panics, stack depth and memory limits provoked; the ELF file inspected. |
| [supply](supply/RESULT.md) | Is what ships what the sources say? | Two builds from scratch compared byte for byte; pinned inputs; the image's contents; the repository and its history; the site's headers and scripts against the live site. |
| [claims](claims/RESULT.md) | Do the documents and the test suite tell the truth? | Every checkable claim of the README, the page and `llms.txt` tested by hand; the suite run against 13 mutants of the lockdown to see which it misses, and three times against the unmodified sources as a baseline. |

Each directory holds `RESULT.md` (what was exercised, what held, what was
not tested, every finding with its reproduction and the reviewer's
verdict), `REPRODUCTION.md` (the reviewer's own runs) and the harness.
Output of the runs is not kept in the repository; the harnesses write it
to `out/`, `work/` or `results/`.

## Result

No way out of the container and no way to gain privilege past the lockdown
was found. The system call filter held completely: the program in the
kernel is the one in the source, every documented refusal is real, and
nothing reaches the same effect by another call.

64 findings were reported. The reviewers reproduced 53 as defects, found
3 already documented and 7 not to be defects, and could not reproduce 1
(which turned out to be a side effect of the test suite; see C-08).

| Severity | Meaning | Reproduced |
| --- | --- | --- |
| critical | escape, or privilege past the lockdown | 0 |
| high | a documented security claim is false | 3 |
| medium | integrity or availability, or misleading security documentation | 7 |
| low | functional | 30 |
| info | | 13 |

The three high findings:

- **Devices.** A device that was not named could be opened for neither
  reading nor writing, which asks Landlock for nothing, and then be driven
  with `ioctl`. The README said such a device could not be opened.
- **`KCOS_DEV` in a subdirectory.** Naming `/dev/net/tun` accounted for
  the whole of `/dev/net`: another device in it could be read.
- **`rm -r DIR/`.** With a trailing slash the kernel follows a link even
  under `O_NOFOLLOW`, so a directory swapped for a link during the call
  had the link's target emptied. The README said a swap could not redirect
  the walk.

Two results are about the project's own assurances and matter as much as
the defects:

- **The test suite missed 8 of 13 deliberate breakages of the lockdown**,
  among them `/sys` writable for root, truncation of program files, and
  removal of files from program directories. A regression there would have
  shipped with a green suite.
- **The suite changed the machine it ran on**: its control run set the
  clock of the Docker VM to 2001 for some seconds on every run, and several
  of its checks depended on timing.

## What was done

43 findings were fixed in code or in the suite and 7 by correcting the
documents; 3 are accepted as they are, 1 is open, and 10 needed no change.

| Track | ID | Severity | Finding | Outcome |
| --- | --- | --- | --- | --- |
| landlock | F1 | high | Any device node opens with access mode 3 and is ioctl-able under init | **Fixed.** The ruleset now handles the device-ioctl right (Landlock ABI 5, Linux 6.10) and grants it only to the listed and named devices. The open itself still succeeds; the README states that and the gap on older kernels. |
| utils | UTILS-1 | high | rm -r DIR/ (trailing slash) follows a symlink swapped in for the operand and empties a tree outside it | **Fixed.** `rm` strips trailing slashes before it opens the operand, and still refuses `LINK/`. |
| claims | C-01 | high | A device named in KCOS_DEV inside a subdirectory of /dev makes every other device in that subdirectory readable | **Fixed.** A `KCOS_DEV` entry accounts only for the node it names; a directory in `/dev` that Docker does not create switches read confinement on. |
| escape-root | ESCROOT-1 | medium | Root under init still reads the host kernel's root-only files in a privileged container | **Documented.** README and page say that only writing is stopped, and what root can read in a privileged container. |
| escape-user | F1 | medium | KCOS_EXEC entries ignored as 'not a plain absolute path' leave their top-level directory writable, contradicting the README | **Fixed.** An ignored `KCOS_EXEC` entry still marks its top-level directory as holding programs. |
| shell | SH-01 | medium | A line continuation inside a token escapes the checks: keywords run as commands (the guarded body runs), other tokens change meaning silently | **Fixed.** Backslash-newline is removed before tokens are recognised, outside single quotes and comments, in one place used by the check and the run. |
| claims | C-03 | medium | Mutant survives: /sys left writable for root | **Fixed.** A root-writable file of `/sys` is opened for appending in the attack list and its control. |
| claims | C-04 | medium | Mutant survives: truncation not handled by the Landlock ruleset | **Fixed.** A program file is truncated in the attack list. |
| claims | C-06 | medium | Mutant survives with a fully green suite: files can be removed from program directories | **Fixed.** Removal and linking in a program directory are in the attack list. |
| claims | C-08 | medium | The suite sets the Docker VM's clock to 2001-01-01 on every run | **Fixed.** The control no longer sets the clock. |
| seccomp | S1 | low | Another process's memory can be read and written under init through /proc/PID/mem, while the Security table says it is refused (reproduced, already documented) | **Documented.** The table names the system calls; the limit covers reading as well as writing through `/proc/PID/mem`. |
| seccomp | S2 | low | Init treats errno 114 from any earlier seccomp filter as proof of lockdown and then silently applies no no_new_privs, no Landlock and no filter | **Fixed.** As PID 1 init no longer asks whether a filter is in place: it applies everything. |
| escape-root | ESCROOT-3 | low | Root can set extended attributes on files in program directories, including /bin/kcontaineros | **Documented.** Extended attributes added to what the owner of a file can still change. |
| escape-root | ESCROOT-4 | low | POSIX message queues cannot be opened under init (mq_open returns EACCES) | **Documented.** POSIX message queues do not work under init. |
| init | INIT-1 | low | A forwarded SIGTTIN or SIGTTOU stops the command for good; docker stop then needs SIGKILL | **Fixed.** As PID 1 init resumes a command stopped by a forwarded `SIGTTIN` or `SIGTTOU`, and follows a forwarded `SIGTERM` with `SIGCONT`. |
| init | INIT-2 | low | Signals 1..16 sent to PID 1 in a loop delay init noticing that the command ended | **Fixed.** Children are collected after every signal, whichever it was. |
| init | INIT-3 | low | A nested init keeps signalling the command's process group after reaping it; a reused PID gets its SIGKILL | **Fixed.** After the command is reaped its process group is signalled by number only when `/proc` cannot be used. |
| init | INIT-4 | low | A nested init kills children it inherited from the program that exec'ed it | **Documented.** A nested init stops every child it has. |
| shell | SH-02 | low | $IFS, $LINENO, $OPTIND, $PS4 expand to nothing, and `set` / `export` without operands print nothing with status 0 | **Fixed.** `$IFS` has its fixed value; `$LINENO`, `$OPTIND`, `$OPTARG` and `$PS4` are syntax errors; `set` and `export` without operands are errors. |
| shell | SH-03 | low | Superlinear time on small input: a command left open across many lines on stdin, and many assignment prefixes on one command | **Fixed.** See memory M-4. |
| shell | SH-05 | low | `cd -` and `command -v` write names to a terminal unfiltered | **Fixed.** Both mask control characters on a terminal. |
| shell | SH-06 | low | Syntax that POSIX shells reject is accepted, twice with another meaning | **Fixed.** An empty command before `;`, a comment as a redirection target and a redirection as a target are syntax errors. |
| shell | SH-07 | low | `command exec REDIRECTION` does not keep the redirection; an assignment is kept when its redirection fails | **Fixed.** `command exec` is refused, and an assignment is made only when the redirections written with it work. |
| utils | UTILS-2 | low | mkdir -p under a umask without owner write/search can chmod a directory outside the operand | **Fixed.** Parents are created with the right mode; nothing is repaired by path afterwards. |
| utils | UTILS-3 | low | uname looks only at its first argument: further options are ignored silently | **Fixed.** `uname` takes one option; more is a usage error. |
| utils | UTILS-4 | low | chmod MODE -- and chown OWNER -- exit 0 without a file operand | **Fixed.** The file operand is required after `--` too. |
| utils | UTILS-5 | low | ls cannot show some symlink operands, and ls -l prints an empty link target with exit 0 when readlink fails | **Fixed.** A link whose target cannot be looked at is shown as itself; a failed `readlink` is an error. |
| utils | UTILS-6 | low | env prints variable names and values raw on a terminal | **Fixed.** `env` masks control characters on a terminal. |
| memory | M-1 | low | Shell recurses into itself in-process when `sh` is not on PATH, until the stack overflows (SIGSEGV) | **Fixed.** The fallback for `sh` starts a new process image through `/proc/self/exe`. |
| memory | M-2 | low | `rm -r` overflows the stack on deep trees when the stack limit is below about 1 MiB | **Fixed.** See utils UTILS-7. |
| memory | M-3 | low | `cd` into a directory whose path is 4096 bytes or longer succeeds but leaves $PWD and $OLDPWD stale | **Fixed.** `cd` fails and returns to where it was when the new place has no name that fits; at start-up `PWD` is unset then. |
| memory | M-4 | low | Two shell inputs take time quadratic in their size | **Fixed.** Unfinished input on stdin is checked again only when a line can end it, and earlier assignments of a command are passed on by reference. |
| supply | S1 | low | site-deploy guard does not see untracked or ignored files in docs/ | **Fixed.** `make site-deploy` refuses on untracked and ignored files in `docs/` too. |
| supply | S2 | low | Untracked files under rootfs/ are shipped in the image | **Fixed.** `tools/mkrootfs.sh` copies the four files by name. |
| claims | C-02 | low | Mutant survives: process_vm_writev removed from the refusal list | **Fixed.** The suite calls every number on the filter's list with arguments no kernel accepts, with a control. |
| claims | C-05 | low | Mutant survives: /dev/shm granted execute (only visible with an exec-mounted /dev/shm) | **Fixed.** A program is run from an exec-mounted `/dev/shm`, with a control. |
| claims | C-07 | low | Three further mutants survive (KCOS_DEV symlink, namespace flags of clone, five calls the suite attacks with busybox) | **Fixed.** The sweep of C-02, a check for a symbolic link in `KCOS_DEV`, and `clone` called with each namespace flag in a combination the kernel calls invalid before anything else. |
| claims | C-09 | low | `make test` is not reliably green: the unmodified sources failed one check in 3 of 3 runs | **Fixed.** Checks no longer depend on the order of two streams, on a PID, or on reading a child's state before its exec. |
| claims | C-10 | low | README: "The top-level directory of an ignored entry is not writable all the same" is false for entries with a trailing slash, `.` or `..` | **Fixed.** Same change as escape-user F1. |
| claims | C-12 | low | Suite checks that prove less than their name says | **Open.** The terminal checks still compare selected lines of a session, and "nobody cannot change the image" has no control. |
| claims | C-15 | low | `ls -a` leaves out `.` and `..`; `set` without arguments prints nothing | **Fixed.** `set` without operands is an error; `ls -a` lists `.` and `..`. |
| landlock | F2 | info | Landlock fails open with only a warning on non-kernel ruleset-build failure | **Fixed.** With Landlock present, a ruleset that cannot be created or applied ends init with status 125. |
| escape-root | ESCROOT-2 | info | Any process under init can change PID 1's limits and scheduling and have the kernel kill it (container exits 137) (reproduced, not a defect) | **No change.** Not a defect: any process may ask the kernel to limit PID 1; the container then ends. |
| escape-root | ESCROOT-5 | info | As root under init, a program carrying file capabilities with the effective bit cannot be started at all | **No change.** A consequence of `no_new_privs` with an empty bounding set. |
| escape-user | F2 | info | Terminal-escape sanitization is bypassed when the container's output is not a tty (default docker run without -t); init/shell/utility messages reach the operator's terminal raw (reproduced, already documented) | **No change.** Documented: masking applies when the output is a terminal. |
| escape-user | F3 | info | README limit understates who can change program-file permissions and timestamps: the owning user, not only root | **Documented.** The limit now says "whoever owns a file". |
| init | INIT-5 | info | A nested init can give up and leave leftovers running; the README does not say so | **Documented.** When it gives up, and when leftovers outside the group are found. |
| shell | SH-04 | info | In the interactive shell a failed `exec COMMAND` ends the session (reproduced, not a defect) | **No change.** Not a defect. |
| shell | SH-08 | info | Error paths where the script goes on, or is silent, unlike busybox sh (reproduced, not a defect) | **No change.** Not a defect. |
| utils | UTILS-7 | info | rm -r crashes with SIGSEGV on a 4096-level tree when the stack limit is 512 kB or less | **Fixed.** The depth `rm -r` goes to is also bounded by the stack limit. |
| utils | UTILS-8 | info | cat and sleep treat -x as an operand: cat -n FILE reads a file named -n if one exists | **Fixed.** `cat` and `sleep` refuse options. |
| utils | UTILS-9 | info | cat does not notice that its output is one of its inputs and fills the filesystem (reproduced, not a defect) | **No change.** Not a defect. |
| memory | M-5 | info | Allocator ignores alignments above 4096 for requests above 64 KiB (latent) | **Fixed.** A request aligned beyond a page that needs its own mapping is refused. |
| memory | M-6 | info | Safe syscall wrappers with unchecked pointer contracts (reproduced, not a defect) | **No change.** Not a defect. |
| memory | M-7 | info | Hardening details not mentioned in the README (reproduced, not a defect) | **No change.** Not a defect. |
| supply | S3 | info | Deploy tool is unpinned: `npx wrangler` with no package.json or lockfile | **Fixed.** The Makefile names the version of `wrangler` it runs. |
| supply | S4 | info | Build is not hermetic; a toolchain pin mismatch would fetch an unpinned compiler | **Accepted.** The build needs the network for the pinned base image only; the toolchain pin and the Dockerfile agree. |
| supply | S5 | info | Git history contains a compiled .pyc with the maintainer's absolute checkout path | **Accepted.** In history only; the file is no longer tracked. |
| supply | S6 | info | test/e2e.sh cleanup removes any container named kcos-*-<PID>, and a default run retags `kcontaineros` | **Fixed.** The suite labels its containers and removes them by label. |
| supply | S7 | info | CSP relies on script-src 'unsafe-inline'; font stylesheet loaded cross-origin without integrity | **Accepted.** The page has no user input and no third-party script. |
| supply | S8 | info | Environment: the shared Docker VM clock was repeatedly at 2001-01-01 during the audit (not reproduced) | **Fixed.** Caused by the suite itself; see claims C-08. |
| claims | C-11 | info | `test` is not a syntax error: a script using it runs on and takes the failure branch (reproduced, already documented) | **No change.** Documented. |
| claims | C-13 | info | "Forwards every signal": SIGCHLD is not forwarded (reproduced, not a defect) | **No change.** Not a defect. |
| claims | C-14 | info | /dev/termination-log is on the device allowlist and no document lists it | **Fixed.** Allowed only where it is a regular file, and listed in the documents. |

After the fixes `make test` passes 504 checks (459 before) and
`make coverage` reaches 99% of lines; each new check belongs to a finding
above. The harnesses for the three high findings were run again on the
fixed image: the swap under `rm -r DIR/` lost nothing in 600 rounds (30 of
300 before), `ioctl` on an unnamed device is refused, and the second device
of a subdirectory cannot be read.

That rerun turned up one more of the same kind, which no track had
reported: a device mapped under the name of one of the links Docker puts
in `/dev` (`--device /dev/x:/dev/core`) counted as a usual entry and could
be read. A usual name now has to be the usual kind of thing, and the suite
checks it.

## What is still open

- **The suite's terminal checks** compare selected lines of a session,
  not the whole of it (C-12), and one check on the image's files has no
  control.
- **Not covered at all:** other kernels and Landlock versions, a Linux
  host with native bind mounts, Kubernetes, user-namespace remapping,
  gVisor or Kata as runtime, and the kernel itself.

## Running it again

The tracks expect three images: `kcontaineros` and `kcontaineros:sealed`
as the Dockerfile builds them, and `kcos-audit`, which is the release
image with a static busybox and `test/probe.rs` in `/bb`, `USER 0` and
`ENV KCOS_EXEC=/bb` (the image `test/e2e.sh` builds for itself, under
another name). Each track's scripts are run from the root of the
repository; a `build.sh` or `00-build.sh`, where there is one, comes
first. They create images and containers named `kcos-audit-TRACK-…` and
remove them. The rules the auditors worked under are worth keeping to:
a time limit on every `docker` command, nothing written to a kernel file
or a device, no block device or hypervisor socket opened without init.
