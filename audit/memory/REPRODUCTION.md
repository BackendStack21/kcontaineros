# Track "memory": independent reproduction

Reviewer run of 2026-11-22 against `kcontaineros:latest` (b1f68e46b287) and
`kcos-audit:latest` (6088d700295c), fresh containers, linux/arm64.

| id | verdict | severity |
|----|---------|----------|
| M-1 | reproduced | low |
| M-2 | reproduced | low |
| M-3 | reproduced | low |
| M-4 | reproduced | low |
| M-5 | reproduced (latent, not reachable from the binary) | info |
| M-6 | reproduced_not_a_defect | info |
| M-7 | reproduced_not_a_defect | info |

None of the seven concerns the lockdown; M-1 behaves the same with and
without init.

## M-1 shell recursion without `sh` on PATH: reproduced, low

```
$ docker run --rm --platform linux/arm64 kcontaineros sh -c 'PATH=/nonexistent; sh -c "$0" "$0"' 'sh -c "$0" "$0"'; echo rc=$?
rc=139
$ ... sh -c 'PATH=; sh -c "$0" "$0"' 'sh -c "$0" "$0"'            -> rc=139
$ docker run --rm --tmpfs /tmp:mode=1777 kcontaineros sh -c 'echo "sh /tmp/s" > /tmp/s; PATH=/nonexistent sh /tmp/s; echo "inner rc=$?"'
inner rc=139
$ docker run --rm --entrypoint /bin/sh kcontaineros -c 'PATH=/nonexistent; sh -c "$0" "$0"' 'sh -c "$0" "$0"'   (no init)
rc=139
```

Control with `sh` on PATH (`docker run -d --name kcos-audit-vmemory-m1 ...
sh -c 'sh -c "$0" "$0"' 'sh -c "$0" "$0"'`): after 5 s still `running`,
5.059 MiB, removed by hand. Cause as stated: `src/sh.rs:831-832` calls
`main()` in-process on ENOENT. The README does not mention the fallback or
a depth limit. Only the script's own process dies, with no message.

## M-2 `rm -r` and a small stack limit: reproduced, low

Auditor's command, with `--ulimit stack=` 524288 / 1048576 / 8388608:

```
stack=524288   rm exit status: 139    ls /tmp -> d
stack=1048576  rm exit status: 0      ls /tmp -> (empty)
stack=8388608  rm exit status: 0      ls /tmp -> (empty)
```

README ("How the tools behave"): rm "refuses ... trees deeper than 4096
levels or than the limit on open files allows". The stack limit is not
named, and the 4094-level tree is inside the stated limit, so the silent
SIGSEGV is not covered. Needs a non-default stack rlimit (Docker's default
8 MiB is fine); nothing is half-removed.

## M-3 `cd` into a path of 4096 bytes or more: reproduced, low

Auditor's command, extended with OLDPWD, `pwd` and a child shell:

```
rc=0 PWD=/tmp OLDPWD=/
                              (ls: empty, the shell is in the deep directory)
--
pwd: .: file name too long
pwd rc=1
child PWD=/lie2               (PWD=/lie2 sh -c 'echo child PWD=$PWD')
/                             (cd - went to the OLDPWD of the cd before)
dd
marker                        (echo x > "$PWD/marker" landed in /tmp)
```

README line 465 says `cd` "sets `PWD` and `OLDPWD` to the physical
directory" with no exception, and the comment at `src/sh.rs:183` says PWD
never follows the environment. Both are false in this case, and `cd`
returns 0: silently different.

## M-4 quadratic inputs: reproduced, low

Auditor's command (no init, busybox drives `/bin/sh`), plus two controls:

```
4000 assignments: 540 ms
8000 assignments: 2310 ms
16000 assignments: 10410 ms
16000 separate lines: 500 ms          (control: linear)
4000 lines: 560 ms        as a file argument: 10 ms
8000 lines: 2000 ms       as a file argument: 20 ms
16000 lines: 7610 ms      as a file argument: 40 ms
```

Doubling the input roughly quadruples the time in both cases. The second
case is specific to a script on stdin; the same text as a file is linear.
Self-inflicted by whoever supplies the script, megabyte-sized input needed.
README says nothing about either.

## M-5 allocator alignment above a page: reproduced, info

`audit/memory/run_alloc.sh` run under my own container name
(`kcos-audit-vmemory-alloc`):

```
--- 1. ... errors=0   errors=0
--- 2. ... max_align=2^16 ... errors=0
--- 3. ops=100000 max_align=2^16 ... errors=2173   (exit status 1)
ERROR misaligned: 0xffffa24f9000 for Layout { size: 66441, align: 8192 (1 << 13) }
ERROR realloc misaligned: 0xffffa24f9000 align 65536
--- 4. ... errors=0
```

`src/main.rs:278-280` returns the mmap address whatever `l.align()` is. A
real violation of the GlobalAlloc contract, unreachable from the shipped
code (no type aligned above a page). Latent.

## M-6 safe wrappers taking raw pointers: reproduced_not_a_defect, info

`python3 audit/memory/unsafe_inventory.py` lists the 15 functions and 36
call sites as stated; `sys::ioctl`, `sys::writev` and `sys::munmap` are
safe `pub fn` taking addresses as integers (`src/sys.rs:222,271,283`). The
facts are right, but no call site is wrong and nothing misbehaves: it is an
API-design observation, consistent with the project's rule that every
syscall is a thin wrapper around `sc()`. I did not re-read all 36 call
sites.

## M-7 hardening details: reproduced_not_a_defect, info

- `src/main.rs:137`: `sys::mprotect_ro(...)` result discarded; `:84`:
  relocation types other than R_AARCH64_RELATIVE skipped. Both as stated by
  reading; neither fails or occurs in the shipped binary
  (`elf_inspect.py`: "every relocation is R_AARCH64_RELATIVE (1027)").
- `cat /proc/self/maps`, three runs: the `rw-p` anonymous mapping ends
  exactly where `/bin/kcontaineros` begins every time
  (`ffff98720000-ffff98760000 rw-p` / `ffff98760000-ffff98766000 r--p`,
  likewise at `ffffae58...` and `ffffabfa...`). The base differs per run,
  so the README's "Code, data, stack and heap are all randomised" is true.
- `elf_inspect.py` on the binary copied out of the image: 22 checks, 1
  failed (`no .comment section`: `rustc version 1.100.0 (0ef1bc386
  2026-11-09)`, `Linker: LLD 23.1.5 ...`), no host path.

No README claim is false; these are suggestions.

## Clean-up

Containers `kcos-audit-vmemory-m1`, `kcos-audit-vmemory-x` and
`kcos-audit-vmemory-alloc` were removed; `docker ps -a --filter
name=kcos-audit-vmemory` is empty. No image was built. Nothing in the repo
was changed except this file.
