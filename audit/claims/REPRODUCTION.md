# Independent reproduction of the "claims" track findings

Reviewer run of 2026-11-22 against `kcontaineros` 0.2.0, `kcos-audit` and
mutant builds made from a copy of the sources (images named
`kcos-audit-vclaims-*`, all removed afterwards). The auditor's helper image
`kcos-audit-claims-img` was gone; `/bb/sc` was rebuilt from
`audit/claims/helper/sc.rs`. Every `docker run` below had `--rm --platform
linux/arm64` and `timeout 120`.

| id | verdict | severity |
|----|---------|----------|
| C-01 | reproduced | high |
| C-02 | reproduced | low |
| C-03 | reproduced | medium |
| C-04 | reproduced | medium |
| C-05 | reproduced | low |
| C-06 | reproduced | medium |
| C-07 | reproduced | low |
| C-08 | reproduced | medium |
| C-09 | reproduced | low |
| C-10 | reproduced | low |
| C-11 | reproduced_but_documented | info |
| C-12 | reproduced | low |
| C-13 | reproduced_not_a_defect | info |
| C-14 | reproduced | info |
| C-15 | reproduced | low |

## C-01 reproduced, high

Script: `(true < /dev/net/other); echo read=$?; (true >> /dev/net/other); echo write=$?` as 65534.

| container | result |
|---|---|
| `--device /dev/zero:/dev/net/tun --device /dev/zero:/dev/net/other -e KCOS_DEV=/dev/net/tun` | read=0 write=1 |
| same, no KCOS_DEV | read=1 write=1 |
| `--device /dev/zero:/dev/net/other --device /dev/zero:/dev/fuse -e KCOS_DEV=/dev/fuse` | read=1 write=1 |
| first row with `--entrypoint /bb/busybox` (control) | read=0 write=0 |
| `--device /dev/zero:/dev/net/other -e KCOS_DEV=/dev/net/nothing` | warning "KCOS_DEV: /dev/net/nothing is not a device in /dev ...: ignored", then read=0 write=1 |
| root, `--device /dev/urandom:/dev/net/other`, sibling named: `head -c 8 /dev/net/other \| wc -c` | 8 (data is read) |
| root, `--device /dev/vda:/dev/kcosdir/disk:r --device /dev/zero:/dev/kcosdir/named -e KCOS_DEV=/dev/kcosdir/named` (under init only, read-only open and close) | unnamed_disk_read_open=0 |
| same without the named sibling | read open = 1 |

New in this run: the named entry need not exist. An entry that init itself
reports as ignored still accounts for the whole subdirectory in
`unusual_devices()` (src/lock.rs:268-272) and switches read confinement off.
README lines 49-51, 97 and 369-370 say an unnamed device cannot be opened,
"for reading or for writing". Writing stays refused.

## C-02 .. C-07 mutants

Each mutant was built from `audit/claims/mutants.py`, with `/bb` added, and
tried next to the unmodified image and to the unmodified image without init.

```
m1  mutant: ret=0                 orig: errno=1                noinit: ret=0          (/bb/sc 271 999999 0 0 0 0 0, privileged root)
m3  mutant: append-open /sys: 0   orig: 1                      noinit: 0              (true >> /sys/kernel/mm/transparent_hugepage/enabled)
m6  mutant: ret=0; 0 bytes        orig: errno=13; 4798136      noinit: ret=0; 0       (chmod 666 /bb/probe; truncate(2); wc -c)
m7  --tmpfs /dev/shm:exec  mutant: hello from prog   orig: Permission denied   noinit: hello from prog
    default /dev/shm       mutant, orig and noinit: Permission denied
m8  mutant: removed               orig: can't remove ... still there   noinit: removed (chmod 777 /bb; rm /bb/probe)
m11 mutant: started               orig: warning KCOS_DEV: /dev/stdin is not a device ...; started
m12 mutant: clone NEWNET errno=1, NEWNS errno=1   orig: the same   noinit: ret=8, ret=10
m13 mutant: mount 14, chroot 14, sethostname 1, clock_settime 14   orig: 1 1 1 1   noinit: 14 14 22 14
```

That no check exists was confirmed by reading test/suite.sh: PROBES (171) has
process_vm_readv but not 271; KERNEL_FILES (771) has no /sys path; `truncate`
and execution from /dev/shm appear nowhere; ATTACKS (130-141) creates and
moves into program directories but never removes.

I ran the project suite once myself, on m8 (`IMG=kcos-audit-vclaims-m8
test/e2e.sh` on a copy): `passed: 458 failed: 1`, the failure being "a shell
that cannot fork says so and goes on" with the same three lines in another
order (see C-09). The mutant survived. For the other mutants the survival
rests on the auditor's logs (audit/claims/mutants/*.failed) and on the
reading above; I did not rerun the suite for them, because every run moves
the VM clock (C-08).

Severities: README line 103 says "`make test` checks each of these", and the
rows name /sys (C-03) and "created, removed or written" (C-04, C-06), so
those are medium. C-02 is one call out of a list whose sibling is probed:
low. C-05 differs only with an exec-mounted /dev/shm: low. C-07: m12 has no
observable effect under init (capabilities refuse it too), m11 loses a
warning only, m13 is the real gap (the filter is untested for calls the
capability drop also refuses): low.

## C-08 reproduced, medium

test/suite.sh:135 has `date -s 2001-01-01` in ATTACKS; lines 168-170 run the
list with `--privileged --user 0 --security-opt seccomp=unconfined
--entrypoint /bb/busybox` and expect rc=0 for it. A sampler container
(`date -u +%s` twice a second) during my single suite run printed:

```
jump: 1795342751 -> 978307200 (2026-11-22 10:19:11 -> 2001-01-01 00:00:00)
jump: 978307217 -> 1795342769 (2001-01-01 00:00:17 -> 2026-11-22 10:19:29)
```

17 seconds in which every container on the daemon saw 2001. AGENTS.md
forbids exactly this in "Writing checks". Not a defect of the image.

## C-09 reproduced, low

Without running the suite again:

```
docker run kcontaineros ps, PID of ps, 20 runs:        6 x5, 7 x14, 8 x1      (suite line 53 pins 7)
docker run -e KCOS_EXEC=/nonexistent/sub:/bb kcos-audit /bb/busybox echo ok 2>&1, 20 runs:
        warning first x18, "ok" first x2                                    (suite line 704)
sleep 1 & grep SigIgn /proc/$!/status, 60 runs:        ...06 x53, ...00 x7    (suite line 651)
```

and my one suite run failed on the order of lines in line 699. All three
kinds are races in the checks, not in the image (the background child
ignores the signals a moment after the fork, as in any shell). Low: a test
reliability problem, though it does hide regressions.

## C-10 reproduced, low

Image `FROM kcontaineros` with /app/data and /app/bin; `sh -c 'echo x > /app/data/f; echo rc=$?'`:

```
KCOS_EXEC=/app/bin/         warning "... is not a plain absolute path: ignored"; rc=0
KCOS_EXEC=/app/./bin        same warning; rc=0
KCOS_EXEC=/app/../app/bin   same warning; rc=0
KCOS_EXEC=/app/nonexistent  warning "... is not a directory ...: ignored"; sh: /app/data/f: permission denied; rc=1
KCOS_EXEC=/app/bin          sh: /app/data/f: permission denied; rc=1
```

README 45-48 lists the trailing slash, `.` and `..` among the ignored
entries and then says the top-level directory of an ignored entry is not
writable. False for those three. Nothing becomes executable.

## C-11 reproduced_but_documented, info

```
$ docker run kcontaineros sh -c 'MODE=prod; test "$MODE" = prod || echo DESTRUCTIVE-BRANCH-RAN; echo "script went on, rc=$?"'
sh: test: not found
DESTRUCTIVE-BRANCH-RAN
script went on, rc=0
```

`printf` and `time` likewise (127, script goes on); `[ a = a ]` and `read x`
are syntax errors with exit 2. README line 472: "`[` and `test` | No | There
is no such command." The behaviour is that of any command that is not
installed, it is loud, and it is what the table says. Refusing `test` in
`check()` would be a reasonable hardening, not a fix of a false statement.

## C-12 reproduced, low

- (2) line 206's command as 65534 with `--entrypoint /bb/busybox`: the same
  three "permission denied" lines and rc 0 as under init.
- (3) `/bb/sc mq kcosq; ls -l /dev/mqueue` as 65534 under init: "mq_open
  errno=13" and `-rw------- 1 nobody nobody 80 ... kcosq`; without init
  "mq_open ok, send=0 receive=6 (stored) unlink=0". Line 788's own command
  without init prints mq=0 shm=0, and the suite has no such control.
- (1), (5) read at the lines given: grep-filtered sessions at 249-263, 657,
  694, 697, 732, 749, 761, 763; stderr discarded at 619 and 645; output to
  /dev/null at 738.
- (6) no setuid or file-capability check: `grep -i 'setuid|suid|setcap'`
  finds only the `ls` and `cp` utility checks.
- (4) line 790-793 uses "$IMG", the full image, and four paths.

README 526 hedges ("wherever they can"); test/e2e.sh:10 says "Every check".

## C-13 reproduced_not_a_defect, info

Signals 1-31 except 9 and 19 sent with `docker kill -s N` to a busybox shell
with a trap on each: every `got-N` printed except `got-17`. init.rs:108 keeps
SIGCHLD for reaping, as every init does; forwarding it would be wrong.
"every signal" (README 14, 455) is loose by one signal that nobody sends to
a container. A wording nit at most.

## C-14 reproduced, info

```
--device /dev/zero:/dev/termination-log   read=0 write=0
--device /dev/zero:/dev/other-log         read=1 write=1   (control without init: read=0 write=0)
```

`termination-log` appears in neither README.md nor docs/llms.txt. It takes
an operator mapping a device to exactly that name.

## C-15 reproduced, low

```
/bin/ls -a  in a directory with .h and v:   .h, v          (busybox: ., .., .h, v)
/bin/ls -A                                  ls: invalid option: -A, rc 1
sh -c 'A=1; set; echo rc=$?'                rc=0, nothing else
```

Neither is mentioned in the README. `set` is documented as accepting `-e`,
`-x` and `-- ARGS`; the bare form is accepted silently.
