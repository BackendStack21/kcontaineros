# Track: memory

What the auditor of this track reported, unedited apart from layout, and what the
independent reviewer made of each finding. The state of the tree is that of 0.2.0
(commit `deffcb4`); what was done about each finding is in [../README.md](../README.md).

## What was exercised

Track "memory", kContainerOS 0.2.0 at deffcb4. No memory-safety defect found, and no reachable panic. The README's claims about the binary hold for the shipped ELF and the running process. Four low-severity bugs (M-1 to M-4) and three informational items (M-5 to M-7).

REPORT.md was NOT written: the Write tool refused it ("Subagents should return findings as text, not write report files"), and I did not route around that with another tool. This result carries the report's content; the harness scripts and audit/memory/run.out (the probes' output as observed) are on disk.

What was exercised:
- (a) Unsafe inventory: 15 `unsafe fn`, 1 `unsafe impl`, 63 `unsafe` blocks (57 are single `sc()` calls in sys.rs), 2 asm items, 3 `static mut`, 1 `from_raw_parts`. 15 safe syscall wrappers take a raw pointer; all 36 path call sites, 6 ioctl sites and 1 writev site were read. 50 syscall numbers and argument orders and 15 kernel structures were compared with the aarch64 ABI by reading; 5 were confirmed at run time against busybox.
- (b) Entry and relocation: source plus disassembly of `_start`/`kcos_start`; 19 run-time probes with a static C helper (argc=0, hostile argv[0], envp without '=', 100,000 env entries, 131,000-byte entries, 100,000 arguments, a 131,071-byte argument to 20 personalities).
- (c) Allocator: the allocator text cut from src/main.rs and compiled with the real sys.rs/util.rs; 1,000,000 operations with about 3,000 live blocks, checking contents, alignment and overlap, including a build with overflow checks. 5 out-of-memory probes (RLIMIT_AS, cgroup limit).
- (d) Panics: every index, slice and conversion on outside data was read. Shell fuzzer in its final form: 160,000 parse-and-expand cases and 40,000 stdin scripts over 8 seeds, plus about 818,000 parse-only cases in earlier runs. Utility fuzzer: 66,000 argument vectors over 20 personalities. No crash, no "internal error", no signal, no hang.
- (e) Stack: disassembly (inline stack probes are present) and 12 probes (`rm -r` at 1001, 4096, 4097 and 5001 levels, four stack limits, nesting 32/33, shell self-recursion).
- (f) ELF: 22 static checks on each of the two binaries; 6 run-time checks on /proc/PID/maps.
- run.sh: 56 result lines from 60 containers (45 held, 5 lines for the 4 findings, 6 notes).

One unexplained event: an early shell-fuzzer run printed mismatches for a contiguous block of cases and I had cut the output, so I cannot say what they were. Four reruns of the same seed gave none. The Docker disk was at 99% (later 100%, with "No space left on device" in another run). The fuzzers now keep cases on tmpfs and re-test every mismatch. I treat it as an environment failure but did not see proof.

The two helper images (kcos-audit-memory-img, kcos-audit-memory-sealed) are removed; `sh audit/memory/build.sh` recreates them and needs the local rust:1-alpine image for gcc. No containers or volumes are left. Nothing outside audit/memory/ was touched.

## What held

- ELF, release (90,240 bytes) and sealed (19,160 bytes): ET_DYN static PIE, no PT_INTERP, no DT_NEEDED, no text relocations, PT_GNU_STACK flags RW, PT_GNU_RELRO present, no W+X segment, no symbol table or debug sections, no build-host path. No BTI/PAC note or instruction and unwind tables present, both as the README says.
- Relocation: 171 relocations, all R_AARCH64_RELATIVE, every offset and addend inside a PT_LOAD, every relocated word inside the range later made read-only. No DT_REL, DT_RELR, DT_JMPREL, init/fini arrays or TLS for the start code to miss. kcos_start (disassembled) uses only registers and PC-relative addressing before relocation is done.
- Running process (`cat /proc/self/maps` under init as nobody): text base differs in each of 5 starts; relocated tables are r--p; .bss, heap chunk and stack are rw-p; nothing is writable and executable. An init that is not PID 1, read with CAP_SYS_PTRACE in a control run, shows the same with no heap chunk.
- Init never allocates: its maps show no anonymous heap chunk, and the sealed binary contains no mmap or munmap syscall.
- No threads and no signal handlers: the only process creation is clone(SIGCHLD) with a null stack (sys.rs:156), and sys::signal only sets SIG_DFL or SIG_IGN. The three `static mut` cannot race.
- All 50 syscall numbers and argument orders in sys.rs match the aarch64 table. 15 kernel structures match the ABI: statx offsets and flags, linux_dirent64, kernel sigaction, 8-byte sigset, timespec, siginfo, utsname, termios, pid_t for TIOC[GS]PGRP, capability header and data, landlock_ruleset_attr, packed landlock_path_beneath_attr, sock_fprog, sock_filter.
- Run-time ABI checks against busybox: `ls -l` mode/uid/gid/size agree with `stat` on a 12,345-byte setuid file owned 123:456; `cp` onto a hard link is refused; `ls -a` agrees for 1- and 255-byte names and five file types; `uname -a` agrees field by field; `ps` handles process names `a) R 1 (b`, `)`, `(`, `((((`, `) ) ) )`, escape codes and the empty name.
- Every path handed to the kernel (36 call sites) is NUL-terminated: a literal, a cz() copy, or a zeroed stack buffer with a length check. argv/envp arrays for execve outlive the call and end in a null. cstr() results from getdents buffers are not used after the buffer is refilled.
- execve with an empty argv gives `kcontaineros: : applet not found`, exit 127, for sh, init and the multi-call name; the sealed init then runs its default command. argv[0] of "", "/", "init/", "/bin/" and "-sh" selects no personality.
- Hostile envp (entries without '=', empty entries, duplicates): the first PATH and the first KCOS_EXEC win in the shell and in init alike. With `KCOS_EXEC=` before `KCOS_EXEC=/bb`, /bb stays non-executable (fails closed). 100,000 env entries and 15 entries of 131,000 bytes work through sh and init.
- 100,000 arguments to echo and one 131,071-byte argument to each of 20 personalities: exit 0, 1 or 127 only.
- Allocator: errors=0 in 600,000 operations with alignments up to 4096 and sizes 1 byte to 1 MiB, in 300,000 with alignments up to 64 KiB and sizes up to 64 KiB, and in 100,000 with overflow checks on. Contents survive realloc, no overlap, no misalignment.
- Out of memory: with RLIMIT_AS at 4 MiB or 511 KiB the result is `kcontaineros: out of memory`, exit 101, no fault; at 512 KiB echo works. Under a 16 MiB cgroup limit the kernel kills the shell and init reports 137.
- Panics: src/ has no unwrap, expect, panic! or division by a variable. Every index and range on outside data is guarded. Arithmetic that feeds a decision uses checked_* or is bounded first (parse_u64, fd numbers, kill pid and signal, chown ids, chmod, umask, shift, sleep).
- Shell fuzzing: 160,000 parse-and-expand cases all ended with exit 2 and a syntax-error line. 40,000 stdin scripts as nobody (3,071 exit 0, 28,245 exit 2, the rest other statuses) gave no crash marker and no signal. About 818,000 further parse-only cases in earlier runs were clean.
- Utility fuzzing: 66,000 argument vectors (numeric edge values, 255/256/4095/4096-byte paths, control bytes, empty strings) over 20 personalities gave exit statuses 0, 1, 2, 126, 127 only.
- Stack probes are present (each 4 KiB step of a large frame is touched; the 64 KiB frame loops), so a large frame cannot step over a guard gap.
- `${A:-...}` nesting: 32 levels expand, 33 are a syntax error before anything runs.
- `rm -r` at the default 8 MiB stack and at 1 MiB: 4096 levels removed, 4097 refused with `directory tree too deep`, descriptor exhaustion refused with `too many open files`, tree left intact, as the README says.
- Error messages to a terminal (512-byte buffer in eprint) arrive complete for names of 480, 491, 492, 511, 512, 513, 1,024 and 100,000 bytes, with control bytes replaced by `?`.
- With descriptors 0, 1, 2 closed in six combinations, eleven commands (66 runs, including init and a pipeline) end with exit 0 or 1 and `cp` still produces an identical copy.
- Below about 436 KiB of address space the kernel kills the execve itself (the image spans 280 KiB because segments are 64 KiB apart); a small static C program still starts at 400 KiB. Not a fault in the binary. `docker run --ulimit stack=8192` makes init die with 139 before it starts the command (fails closed).

## Not tested

- REPORT.md was not written: the Write tool refused report files for subagents. Its content is in this result.
- Kernels with 16 or 64 KiB pages (the RELRO rounding was checked by arithmetic in elf_inspect.py only), kernels before 5.18 (a real argc == 0; main.rs:154,159 handle it by reading), kernels without Landlock. Only kernel 7.0.14-linuxkit was available.
- The panic handler at run time: no input was found that panics, and no modified binary was built to force one (Docker disk was full). Its behaviour (write `kcontaineros: internal error`, exit_group(101), no unwinding) is stated from main.rs:217-222 and from the string being present in both binaries.
- PID 1's own memory map (not dumpable, by design) and the sealed image's process at run time. An init that is not PID 1 was read in a control run with CAP_SYS_PTRACE, and the sealed ELF was inspected statically.
- RLIMIT_DATA under init: `docker run --ulimit data=...` makes runc itself fail to start, and Docker has no `as` ulimit. RLIMIT_AS was applied through the helper without init instead.
- The mprotect failure path (M-7), a root filesystem returning names longer than 255 bytes at `/` (lock.rs:177-179 would hit a bounds check and exit 101 before the command starts), and a missing /proc.
- The interactive (terminal) shell under fuzzing, and the coverage (`cov`) build, which is never shipped.
- The fuzzers are grammar-based with no coverage feedback; they speak to crashes, signals and hangs, not to whether the shell's or the utilities' answers are right.
- One early shell-fuzzer run reported mismatches I could not examine (output was cut) and that four reruns of the same seed did not reproduce; attributed to the Docker disk being full, not proven.

## Findings

### M-1 — Shell recurses into itself in-process when `sh` is not on PATH, until the stack overflows (SIGSEGV)

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/sh.rs:831-832 (exec_or_die calls main() again after ENOENT)

When exec of `sh` fails with ENOENT, exec_or_die runs the shell's main() again inside the same process instead of replacing the process. A script whose last command is `sh ...` and that reaches itself this way never returns from those calls and exhausts the stack. With `sh` on PATH the same script replaces itself by exec forever with constant memory. The process dies under the kernel's stack guard; nothing else is corrupted. A script file reproduces it too: `echo 'sh /tmp/s' > /tmp/s; PATH=/nonexistent sh /tmp/s` ended with signal 11.

Reproduction:

```
docker run --rm --platform linux/arm64 kcontaineros sh -c 'PATH=/nonexistent; sh -c "$0" "$0"' 'sh -c "$0" "$0"'; echo $?
```

Expected: An error, or the endless exec loop the same script gives with sh on PATH (a 5 s timeout expired there, exit 124); no crash.

Observed: No output, exit status 139 (SIGSEGV) in under a second. Same with `PATH=`.

Reviewer: Not a lockdown issue (identical with and without init). README does not mention the in-process fallback or any depth limit. Only the script's own process dies, silently, of SIGSEGV; needs sh missing from PATH plus self-recursion.

### M-2 — `rm -r` overflows the stack on deep trees when the stack limit is below about 1 MiB

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/applets.rs:789-854 (RM_MAX_DEPTH, Rm::at); README "How the tools behave"

The comment at applets.rs:789 says the 4096-level limit bounds both descriptors and stack, and the README says trees are refused beyond 4096 levels or the open-file limit. The stack limit is not considered. A level costs between 128 and 256 bytes, so a 4094-level tree needs more than 512 KiB. With a smaller stack rlimit, rm dies of SIGSEGV with no message instead of refusing. Nothing is half-removed, because removal starts at the bottom.

Reproduction:

```
P=$(python3 -c "print('d/'*2047)"); docker run --rm --platform linux/arm64 --ulimit stack=524288 --tmpfs /tmp:mode=1777 kcontaineros sh -c 'cd /tmp; mkdir -p "$1"; cd "$1"; mkdir -p "$1"; cd /; rm -r /tmp/d; echo "rm exit status: $?"; ls /tmp' sh "$P"
```

Expected: The 4094-level tree removed (`rm exit status: 0`, as with --ulimit stack=1048576 and with the default), or a message such as `directory tree too deep`.

Observed: `rm exit status: 139`, nothing printed by rm, `d` still listed in /tmp.

Reviewer: The 4094-level tree is within the documented limit, so the silent crash is not covered by the README. Requires a non-default stack rlimit (Docker default 8 MiB works); nothing is half-removed.

### M-3 — `cd` into a directory whose path is 4096 bytes or longer succeeds but leaves $PWD and $OLDPWD stale

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/sh.rs:924-939 (cd builtin), src/sh.rs:184-188 (start-up)

After chdir succeeds, getcwd into a 4096-byte buffer fails and the result is ignored: cd returns 0 without updating PWD or OLDPWD. The shell is then in one directory while $PWD names another, so anything addressed through "$PWD/..." lands in the wrong place, and a later `cd -` goes to the OLDPWD of the cd before. This is "silently different", which the project rules exclude. Start-up has the same gap: when getcwd fails, an inherited PWD is kept, contrary to the comment "PWD is where the shell is, whatever the environment claimed" (a child sh started in the deep directory printed PWD=/tmp, and PWD=/lie2 when given that). `pwd` there fails loudly (`pwd: .: file name too long`, exit 1).

Reproduction:

```
P=$(python3 -c "print('dd/'*1364)"); docker run --rm --platform linux/arm64 --tmpfs /tmp:mode=1777 kcontaineros sh -c 'cd /tmp; mkdir -p "$1"; cd "$1"; echo "rc=$? PWD=$PWD"; echo x > "$PWD/marker"; ls; echo --; cd -; ls /tmp' sh "$P"
```

Expected: PWD naming the new directory and `marker` created in it, or `cd` failing with a message.

Observed: Output: `rc=0 PWD=/tmp`, then nothing from `ls` (the shell is in the empty deep directory), `--`, `/` (where `cd -` went), then `dd` and `marker` listed in /tmp.

Reviewer: README line 465 says `cd` "sets `PWD` and `OLDPWD` to the physical directory" with no exception, so this is undocumented and contradicts the project's "correct or loud" rule: a write to "$PWD/marker" landed in /tmp instead of the current directory. Needs a path of 4096 bytes or more.

### M-4 — Two shell inputs take time quadratic in their size

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/sh.rs:1293 (overlay: cmd.assigns.clone()), src/sh.rs:258-277 (re-check of unfinished stdin input)

(1) Each assignment in one command clones all earlier assignments of that command, in check() and again when run. (2) A script on stdin that leaves a `${` open is re-checked from its first byte for every further line; only open quotes are exempt from the re-check. Ten times the input costs a hundred times the wait. Only whoever supplies the script is affected.

Reproduction:

```
docker run --rm --platform linux/arm64 --tmpfs /tmp:size=64m -e PATH=/bb:/bin --entrypoint /bb/busybox kcos-audit sh -c 'now() { read u _ </proc/uptime; echo ${u%.*}${u#*.}; }; for n in 4000 8000 16000; do awk -v n=$n "BEGIN{for(i=0;i<n;i++) printf \"V%d=%0100d \", i, 0; print \":\"}" > /tmp/s; s=$(now); /bin/sh /tmp/s; e=$(now); echo "$n assignments: $(( (e-s)*10 )) ms"; done; for n in 4000 8000 16000; do awk -v n=$n "BEGIN{print \"echo \${A:-\"; for(i=0;i<n;i++) printf \"%080d\n\", 0; print \"} >/dev/null\"}" > /tmp/s; s=$(now); /bin/sh </tmp/s; e=$(now); echo "$n lines: $(( (e-s)*10 )) ms"; done'   # also run by: bash audit/memory/run.sh
```

Expected: Time proportional to input size (16,000 assignments on separate lines take 490 ms).

Observed: One command with 4000 / 8000 / 16000 assignments (0.4 / 0.8 / 1.7 MB): 520 / 2450 / 10350 ms. Stdin with an open `${` and 4000 / 8000 / 16000 lines: 540 / 2020 / 7590 ms.

Reviewer: Doubling the input roughly quadruples the time in both cases. Self-inflicted by whoever supplies the script and needs megabyte-sized input; no security boundary involved. README is silent on it.

### M-5 — Allocator ignores alignments above 4096 for requests above 64 KiB (latent)

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: src/main.rs:278-280 (Heap::alloc, own-mapping path), also realloc at 311-321

A request too large for a size class gets its own mapping, and the page-aligned address is returned whatever l.align() is. GlobalAlloc requires the alignment to be honoured. Nothing in the binary has a type aligned above 16 bytes, so this is not reachable today; it becomes a real fault if a type with alignment above a page is ever added.

Reproduction:

```
sh audit/memory/run_alloc.sh   # case 3: alignments above 4096 with sizes above 64 KiB
```

Expected: errors=0, as in cases 1, 2 and 4.

Observed: `ERROR misaligned: 0xffff9b491000 for Layout { size: 318651, align: 65536 (1 << 16) }` and similar; `ops=100000 max_align=2^16 ... errors=2107`, exit status 1.

Reviewer: A real violation of the GlobalAlloc contract, but latent: the harness calls the allocator directly with layouts nothing in the shipped binary requests. No runtime impact today. The auditor's error count (2107) differs from mine (2173), presumably from the randomised seed/addresses.

### M-6 — Safe syscall wrappers with unchecked pointer contracts

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced, not a defect
- Where: src/sys.rs (open, openat, execve, access_x, chdir, statx, mkdir, unlinkat, rename, symlink, link, chmod, chown, utimes_now, readlink; ioctl, writev, munmap)

Fifteen `pub fn` take `*const u8` and are not `unsafe`, although the pointer must be a NUL-terminated string (or NULL-terminated array) that outlives the call. sys::ioctl takes the argument pointer as a usize, sys::writev takes pointer/length pairs as integers, and sys::munmap takes any address. Safe code can therefore make the kernel read or write anywhere, and the compiler gives no help on the next change. All 36 path call sites, the 6 ioctl sites and the single writev site are correct today.

Reproduction:

```
python3 audit/memory/unsafe_inventory.py
```

Expected: Functions whose callers carry a memory-safety obligation are `unsafe fn`, or take a type that proves it (a NUL-terminated wrapper type, &[IoSlice]).

Observed: The script lists 15 safe functions taking a raw pointer and 36 call sites outside sys.rs.

Reviewer: The facts are accurate, but nothing misbehaves and the auditor found every call site correct; this is an API-design suggestion, not a defect in the image. I did not independently re-read all 36 call sites.

### M-7 — Hardening details not mentioned in the README

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced, not a defect
- Where: src/main.rs:84, src/main.rs:137, allocator chunk placement, ELF .comment

(1) The result of the mprotect that makes the relocated tables read-only is discarded; where it fails the process runs on with writable tables and says nothing. It succeeded in every run here. (2) kcos_start silently skips any relocation that is not R_AARCH64_RELATIVE instead of stopping; there is none today, but a toolchain or flag change that introduces one would give a binary that starts and then misbehaves. (3) The first heap chunk is always directly below the image, so heap and code are randomised together and one heap address reveals the code base; the README's "all randomised" is true as written. (4) .comment carries the exact compiler and linker versions, no host information.

Reproduction:

```
python3 audit/memory/elf_inspect.py /path/to/extracted/kcontaineros; docker run --rm --platform linux/arm64 kcontaineros cat /proc/self/maps
```

Expected: n/a (informational)

Observed: elf_inspect: 21 of 22 checks ok; the one FAIL is `no .comment section` (`rustc version 1.100.0 (0ef1bc386 2026-11-09)`, `Linker: LLD 23.1.5 ...`). maps: `ffff811a0000-ffff811e0000 rw-p` (heap) immediately followed by `ffff811e0000-ffff811e6000 r--p ... /bin/kcontaineros`, in every run.

Reviewer: All four observations hold, but none makes a README claim false: "Code, data, stack and heap are all randomised" is true as written, RELRO is applied in every run, and no other relocation type exists in the shipped binary. Hardening suggestions only. The auditor's summary says "21 of 22 checks ok", consistent with my run.

