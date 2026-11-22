# Track: utils

What the auditor of this track reported, unedited apart from layout, and what the
independent reviewer made of each finding. The state of the tree is that of 0.2.0
(commit `deffcb4`); what was done about each finding is in [../README.md](../README.md).

## What was exercised

Utilities track (src/applets.rs, src/util.rs, dispatch in src/main.rs), all observed in real containers on linux/arm64, mostly under /sbin/init as root without capabilities, with a control without init. One high finding: `rm -r DIR/` (trailing slash) follows a swapped-in symlink and empties a tree outside the operand, contradicting the README. Eight lesser findings; everything else held.

REPORT.md was NOT written: the Write tool refused it ("Subagents should return findings as text, not write report files") and I did not work around that through the shell. Its content is this result; the harness and raw logs are in audit/utils/.

Exercised:
- Options and numbers: 1763 cases. 94 printable characters as an option letter for 16 utilities (1504), 75 second-position/long-option forms, 71 operand-count forms, 113 number forms for kill/sleep/chmod/chown (0, negative, 2^31, 2^32, 2^32+PID, 2^64, 38 digits, signs, spaces, hex, non-ASCII digits), with a victim process checked after each kill case.
- Differential against busybox 1.38.0: 526 cases under init, 525 without. Compared exit status, stdout and the resulting tree (type, mode, size, links, owner, link target, content hash, mtime). Corpus: names with space, newline, control and 8-bit bytes, leading dashes, a 255-byte name; unreadable, read-only and sticky directories; symlinks to file/dir, dangling, loops; FIFO, socket, hard link, setuid/setgid files, 3 GB sparse file; umasks 0 to 0777; output to /dev/full and closed descriptors. 480 of 526 matched under init.
- ls: 44 comparisons against busybox stat, 27 exit-status cases.
- Terminal: 48 cases on a pty with ESC, BEL, 0x01, 0xff, 0x9b, CR, TAB and newline in names, arguments, process name, argv, argv[0] and environment.
- Safety: 132 rm refusal cases (33 spellings of /, . and .. times 4 flag forms) with canaries; trees of 1000 to 20000 levels and of 255-byte names; descriptor and stack limits; 65 cases on paths of 4094 to 5000 bytes; 100000-entry directory on tmpfs, 22000 on overlayfs; special files, full tmpfs, RLIMIT_FSIZE; files changing during rm/ls/cp (150 + 300 rounds); read-only root (18 commands, two implementations, with and without init).
- Races: rm -r against a directory/symlink swap, 4 variants x 300 rounds for kcontaineros and busybox (2400 rounds); mkdir -p under umask 0300, 600 rounds each.
- Dispatch: 181 cases (53 argv vectors including argc 0, 80 applet/form combinations, 44 unwritable-output cases, large output to a closing pipe and a full tmpfs).

Cleanup: image kcos-audit-utils-img removed, no containers left, nothing outside audit/utils/ touched. The helper binary is not kept; 00-build.sh rebuilds it (from rust:1-alpine if present, otherwise alpine with apk add gcc musl-dev).

## What held

- Every unknown single-letter option is an error (exit 1, message) for cat chmod chown cp env kill ln ls mkdir mv ps pwd rm sleep touch uname; only ls -l -a, rm -r -f, mkdir -p, ln -s, env -i, kill -0..-9 and uname -a -n -r -m -s exit 0 (1504 cases).
- kill accepts only decimal PIDs 1..2^31-1: 0, -1, -- -1, -PID, 2^31, 2^32, 2^32+PID, 2^64, 38 digits, +PID, spaces, hex and non-ASCII digits were all rejected and the victim process survived each.
- sleep, chmod and chown rejected every overflow, sign, hex, non-ASCII-digit and malformed form with a message and exit 1; no panic (exit 101) or hang in any of the 1763 cases.
- rm refused all 33 spellings of /, . and .. (//, /., ./, sub/.., /tmp/../.., link-to-root/. and so on) in all four flag forms; canary tree and / were unchanged.
- rm never followed a symlink operand when nothing was swapping it: `rm -rf link/` gives 'not a directory' and leaves the target intact, also for /proc/self/root/ and /proc/self/cwd/.
- rm -r without a trailing slash on the operand, and for a directory swapped below the operand, deleted nothing outside the tree in 300 + 300 race rounds (busybox lost files in 37 and 21 of 300).
- rm -r removed 4096 nested levels and refused 4097, 4098, 6000 and 20000 with one 'directory tree too deep' message, exit 1, nothing removed; removed 3000 levels of 255-byte names (768 kB path); reported 'too many open files' once under a 64-descriptor limit.
- rm -r reported each entry it could not remove once, emptied a directory it could not delete, and exit 0 always meant the operand was gone (150 rounds against a process refilling the directory: 0 violations).
- cp drops setuid, setgid and sticky bits on a newly created copy, also with umask 0 and with capabilities (busybox keeps them there); it refuses the same file via hard link, symlink and ./a. An existing destination keeps its own mode bits, as with any cp.
- cp reports ENOSPC, EFBIG, EROFS and EACCES naming the destination with exit 1; a partial copy is left only together with that message. mv across filesystems fails with the source intact.
- ls and ls -l matched busybox stat for 42 of 44 comparisons (mode strings including s/S/t, sizes, link targets, sort order); 100000 entries listed in the same order as busybox ls -1; ls -l of a churning directory gave no error in 300 runs.
- 46 of 48 terminal cases emitted only printable ASCII and newlines: ls, ls -l, link targets, headers, pwd, ps (hostile comm and argv, also when not on a terminal), all utility error messages, 'applet not found' for a hostile argument and a hostile argv[0], and a 250-byte name of ESC bytes.
- Every utility and kcontaineros --list/--help/--version/-V/-h exit 1 when stdout is /dev/full or closed, also with all three descriptors closed (busybox env, pwd and uname exit 0 there).
- argv[0] dispatch runs only exact applet names (basename of argv[0] or of the first argument after 'kcontaineros'); argc 0, empty, 'ls/', 'LS', 'ls ', '-sh', names with 0x01/0xff/newline, a 100000-byte name and nested 'kcontaineros kcontaineros' all give 'applet not found', exit 127.
- On a read-only root every modifying utility failed with 'read-only file system' and exit 1, with and without init; /etc was unchanged.
- Paths of 4096 bytes and more fail with 'file name too long' and exit 1 in all 13 tools tried; 4095 bytes work.
- The 46 differential differences under init are: unsupported options or forms that fail loudly (uname -sn/-v/-o, kill -l, rm -R, ln into a directory, mv across filesystems), cases where kcontaineros behaves as GNU does and busybox does not (cp onto a link to itself, echo -eE order and \0NNN, mv over a symlink loop, rm of 'file/'), busybox exiting 0 on unwritable stdout, and the findings listed.

## Not tested

- REPORT.md was not delivered: the Write tool refused report files for this subagent and I did not bypass that with a shell redirect. Scope, method, counts, results and limits are in this structured result instead.
- run-all.sh as a whole was not executed end to end after the last edits; each of the six scripts it calls was run on its own in its final form, except that 04-safety.sh and 05-dispatch.sh/06-ls.sh tee to out/safety.txt, out/dispatch.txt and out/ls.txt, which I removed after copying them to the numbered files.
- Block devices and character devices other than the standard ones in /dev: none can be created without CAP_MKNOD, and the rules forbid opening them in a run without init.
- A race built from busybox tools alone, as the task suggested: busybox mv cannot exchange a directory and a symlink atomically, so the swap used renameat2(RENAME_EXCHANGE) from the C helper. Hit rates (15 to 44 of 300 for rm, 1 to 3 per 400-600 for mkdir) are from this machine only.
- cp and touch destination races: both follow a destination symlink by design, as busybox does, so a swap adds nothing an attacker with write access to the directory does not already have.
- Filesystems other than tmpfs and overlayfs (no NFS, FUSE or Docker Desktop bind mount), other kernels, user-namespace remapping.
- uname -n with a hostile host name on a terminal: Docker rejects such host names.
- Memory limits of ls beyond 100000 entries, and rm -r stack use at depths other than 4096.
- The sealed image: it contains no utilities.
- Observed in passing, belongs to the init track and not pursued: as root under init, `ls -l /proc/1/fd` lists PID 1's descriptors (names only, targets unreadable); /proc/1/environ, maps, cwd and exe were denied.

## Findings

### UTILS-1 — rm -r DIR/ (trailing slash) follows a symlink swapped in for the operand and empties a tree outside it

- Severity: auditor **high**, reviewer **high**
- Reviewer's verdict: reproduced
- Where: src/applets.rs:804-819 (Rm::at: unlinkat then openat on the operand as typed), called from rm() at line 876

README, Security: "rm -r walks the tree through directory descriptors opened without following symlinks, so a symlink swapped in during the walk cannot send it elsewhere." That is false when the operand ends in a slash. Rm::at first calls unlinkat(AT_FDCWD, "x/") (EISDIR while x is a directory), then openat(AT_FDCWD, "x/", O_RDONLY|O_DIRECTORY|O_NOFOLLOW). The kernel follows a final symlink when the path has a trailing slash, O_NOFOLLOW notwithstanding, so if x is exchanged for a symlink between the two calls, rm opens the link's target and deletes everything in it. Names below the operand come from getdents and never carry a slash, which is why only the operand itself is affected. The swap was done with renameat2(RENAME_EXCHANGE) from a helper; that call is not filtered under init. Without a swap the same operand is safe (`rm -rf link/` says 'not a directory').

Reproduction:

```
audit/utils/00-build.sh
timeout 280 docker run --rm -i --platform linux/arm64 --tmpfs /work:size=32m --pids-limit 512 --memory 512m kcos-audit-utils-img /bb/busybox sh -s k slash 300 < audit/utils/in/race-rm.sh
# same with 'k relslash 300' (relative operand x/), and for contrast 'k plain 300' and 'k nested 300'
```

Expected: RESULT impl=k variant=slash rounds=300 rounds-with-victim-files-deleted=0

Observed: first loss in round 22: 0 of 16 victim files left, rm exit 1 / RESULT impl=k variant=slash rounds=300 rounds-with-victim-files-deleted=30 rm-exit-0=102 / (relslash: 31 of 300; two earlier runs of slash: 44 and 15 of 300. plain: 0 of 300, nested: 0 of 300.)

Reviewer: Could not refute. The victim is reachable only through the symlink, the flipper is killed before counting, and the two variants without a trailing slash lose nothing, which fits the stated mechanism (unlinkat then openat with O_NOFOLLOW on an operand ending in '/', src/applets.rs Rm::at). Ordinary file semantics, not the lockdown, so no init/no-init control applies. The attacker needs write access to the operand's parent directory. busybox has the same race but makes no such claim; here a documented security claim is false, hence high.

### UTILS-2 — mkdir -p under a umask without owner write/search can chmod a directory outside the operand

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/applets.rs:702-709 (mkdir: stat then sys::chmod by path on a parent it just created)

When the umask removes owner write or search, mkdir -p repairs each new parent with stat(path, nofollow) followed by chmod(path), and fchmodat follows symlinks. If the new parent is exchanged for a symlink between the two calls, the link's target gets the parent's mode with u+wx added. Needs an unusual umask, write access to the directory where the parent is created, and a narrow window, hence low.

Reproduction:

```
audit/utils/00-build.sh
timeout 900 docker run --rm -i --platform linux/arm64 --tmpfs /work:size=64m --pids-limit 4096 --memory 1g kcos-audit-utils-img /bb/busybox sh -s < audit/utils/in/safety.sh | grep -A4 '== mkdir -p under umask'
# the loop: victim directory mode 500; /bb/h flip /work/mt/p /work/mt/pl (pl -> victim); ( umask 0300; /bin/mkdir -p /work/mt/p/q )
```

Expected: /bin/mkdir -p flip, 600 rounds: rounds in which a directory outside the operand was chmod-ed: 0

Observed: round 262: mode of the directory outside the operand changed from 500 to 777 / /bin/mkdir -p flip, 600 rounds: rounds in which a directory outside the operand was chmod-ed: 1 / (an earlier run: 3 of 400. busybox mkdir -p: 0 of 600.)

Reviewer: 777 is what the code computes for a parent created under umask 0300 (0477 | 0300), applied through the link by the path-based chmod at src/applets.rs:702-709. Needs a umask without owner write/search plus an attacker who can write where the parent is created, so low stands. README is silent on it.

### UTILS-3 — uname looks only at its first argument: further options are ignored silently

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/applets.rs:972-982

AGENTS.md and the README say an option a tool does not have is an error and that behaviour is never silently different. uname matches only a[1]; anything after it, valid or not, is ignored with exit 0. `uname -s -n` therefore prints less than was asked for without saying so.

Reproduction:

```
docker run --rm --platform linux/arm64 kcontaineros uname -s -n; echo rc=$?
docker run --rm --platform linux/arm64 kcontaineros uname -a --bogus -Z; echo rc=$?
```

Expected: Either 'Linux <nodename>' (busybox prints 'Linux 62ecbfdc813e'), or an error and exit 1; for --bogus an 'invalid option' error and exit 1.

Observed: Linux / rc=0 / Linux 0b1c618e2f4d 7.0.14-linuxkit #1 SMP PREEMPT Tue Nov 10 17:08:40 UTC 2026 aarch64 / rc=0

Reviewer: README line 473 says "an unknown option is an error"; that holds only for uname's first argument. Functional, no security effect.

### UTILS-4 — chmod MODE -- and chown OWNER -- exit 0 without a file operand

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/applets.rs:188 and 199 (chmod), 217 and 232 (chown): the operand count is checked before the second '--' is skipped

The usage check counts the '--' that may follow the mode or owner as a file. With nothing after it the loop runs zero times and the tool exits 0 silently, where `chmod 644` alone is a usage error.

Reproduction:

```
docker run --rm --platform linux/arm64 kcontaineros chmod 644 --; echo rc=$?
docker run --rm --platform linux/arm64 kcontaineros chown 0 --; echo rc=$?
docker run --rm --platform linux/arm64 kcontaineros chmod 644; echo rc=$?
```

Expected: chmod: usage: chmod OCTAL FILE...  and rc=1 in all three

Observed: rc=0 / rc=0 / chmod: usage: chmod OCTAL FILE... / rc=1

Reviewer: Matches the source: the operand count is checked before the second '--' is skipped (src/applets.rs chmod and chown).

### UTILS-5 — ls cannot show some symlink operands, and ls -l prints an empty link target with exit 0 when readlink fails

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/applets.rs:661-666 (only ENOENT and ELOOP fall back to showing the link) and 620-625 (readlink result clamped with r.max(0))

Two related defects. (1) A symlink given as an operand is shown as itself only when opening it fails with ENOENT or ELOOP. With EACCES (target inside an unreadable directory) or ENAMETOOLONG (4000-byte target) ls reports the error against the link's name and shows nothing, though the same link is listed fine as a directory member. (2) In ls -l a failed readlink is treated as an empty target: the line reads 'NAME -> ' and the exit status is 0.

Reproduction:

```
docker run --rm --platform linux/arm64 kcontaineros sh -c 'cd /tmp && ln -s /root/x l && ls -l l; echo "rc=$?"; ls -l'
docker run --rm --platform linux/arm64 kcos-audit ls -l /proc/1/fd; echo rc=$?
```

Expected: First: 'lrwxrwxrwx 65534 65534 7 l -> /root/x', rc=0 (busybox ls -l shows the link). Second: an error for each link that cannot be read and exit 1, or no ' -> ' at all.

Observed: ls: l: permission denied / rc=1 / lrwxrwxrwx 65534 65534 7 l -> /root/x /  / lrwx------ 0 0 64 0 ->  / l-wx------ 0 0 64 1 ->  / l-wx------ 0 0 64 2 ->  / rc=0

Reviewer: Both halves reproduce. The readlink refusal on /proc/1/fd is itself the documented "PID 1 is opaque" behaviour (the control without init shows the targets); the defect is that ls prints an empty target and exits 0. I did not rerun the ENAMETOOLONG case from the description, only EACCES.

### UTILS-6 — env prints variable names and values raw on a terminal

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/applets.rs:459-463 (Out::s, not Out::safe)

The only path found that puts externally supplied bytes on a terminal unchanged (echo and cat excepted by design). The README's list (ps, ls, pwd, error messages) does not include env, so no documented claim is broken, but AGENTS.md's rule is 'Nothing untrusted reaches a terminal raw' and an environment value is as foreign as a file name. 46 other terminal cases were clean.

Reproduction:

```
python3 test/term.py -- docker run -it --rm --platform linux/arm64 -e "A=$(printf '\033]0;owned\007\033[31mred')" kcontaineros env | od -c
# or: audit/utils/00-build.sh && audit/utils/03-terminal.sh
```

Expected: A=?]0;owned??[31mred

Observed: A = 033 ] 0 ; o w n e d \a 033 [ 3 1 m r e d \n  (ESC and BEL reach the terminal; 03-terminal.sh reports 'RAW env print' and 'RAW env name' with bytes 01 07 09 0d 1b 9b ff)

Reviewer: No README claim is false: env is not in the README's list, and the README does not state env as an exception either. The rule broken is the internal one in AGENTS.md ("Nothing untrusted reaches a terminal raw"). The environment is normally set by whoever starts the container, so impact is small. A reasonable reader could class this as intended, like echo and cat; I kept it as a low defect because of the project's own rule.

### UTILS-7 — rm -r crashes with SIGSEGV on a 4096-level tree when the stack limit is 512 kB or less

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: src/applets.rs:804 (Rm::at recursion), RM_MAX_DEPTH at 791

The comment on RM_MAX_DEPTH says the constant bounds the stack; it does so only for a stack of about 1 MB or more. With the default 8 MB limit and with 1 MB the 4096-level tree is removed. With 512 kB, 256 kB or 64 kB the process is killed by SIGSEGV with no message; nothing has been removed at that point because deletion happens on the way back up. The README names depth and open files as limits, not the stack.

Reproduction:

```
audit/utils/00-build.sh
docker run --rm --platform linux/arm64 --tmpfs /work kcos-audit-utils-img /bb/busybox sh -c '/bb/h mkdeep /work/d 4096 x; ulimit -s 512; rm -r /work/d; echo "rc=$?"; /bb/h depth /work/d x'
```

Expected: rc=0 and 0 levels left, or an error message and exit 1

Observed: Segmentation fault / rc=139 / 4096

Reviewer: Only under a stack limit lowered below the 8 MB default, and nothing is removed when it crashes. README (lines 184-185) names depth and open files as limits, not the stack; the RM_MAX_DEPTH comment overstates what the constant bounds. Info is right.

### UTILS-8 — cat and sleep treat -x as an operand: cat -n FILE reads a file named -n if one exists

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: src/applets.rs:79-87 (operands()), used by cat and sleep

The README says 'an unknown option is an error'. For cat that holds only by accident: -n is opened as a file, which normally fails ('cat: -n: no such file or directory', exit 1, the other operands still printed). If the working directory holds a file of that name it is printed and the exit status is 0. The source comment says this is intended; the README does not.

Reproduction:

```
docker run --rm --platform linux/arm64 kcontaineros sh -c 'cd /tmp && echo secret > ./-n && cat -n /etc/os-release; echo "rc=$?"'
```

Expected: cat: invalid option: -n  and rc=1

Observed: secret / NAME="kContainerOS" / ID=kcontaineros / ... (rc=0)

Reviewer: Intended according to the comment on operands() in src/applets.rs ("a file named -x is just a file"), but README line 473 says "an unknown option is an error" without carving cat out. A documentation mismatch more than a bug, and silent only when a file named like the option exists. sleep is loud either way, so the finding really concerns cat alone.

### UTILS-9 — cat does not notice that its output is one of its inputs and fills the filesystem

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced, not a defect
- Where: src/applets.rs:139-180 (pump_between, cat)

`cat a >> a` and `cat a b > b` read what they have just written until the filesystem is full, then fail with 'cat: write error: no space left on device', exit 1. busybox behaves the same; GNU cat refuses ('input file is output file'). cp has such a check, cat does not.

Reproduction:

```
audit/utils/00-build.sh
docker run --rm --platform linux/arm64 --tmpfs /work:size=16m kcos-audit-utils-img /bb/busybox sh -c 'cd /work; echo data > a; /bin/cat a >> a; echo "rc=$?"; /bb/busybox stat -c %s a'
```

Expected: An error naming the file, with a left at 5 bytes; or a single copy appended (10 bytes).

Observed: In the differential run (48 MB tmpfs): 'cat: write error: no space left on device', exit 1, and a had grown to 50159616 bytes (out/diff-init.tsv, case 'cat [a]  >> a').

Reviewer: Happens as described, but it matches busybox, POSIX does not require a check, the failure is loud (exit 1), and the README claims a self-copy refusal for cp only. A hardening idea, not a defect against any stated behaviour.

