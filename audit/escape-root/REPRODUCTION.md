# escape-root: independent reproduction

Helper image rebuilt from this directory's Dockerfile as `kcos-audit-vescape-root-img`
(the auditor's `kcos-audit-escape-root-img` was gone) and removed afterwards.
`P` = `--rm --platform linux/arm64 --privileged --security-opt seccomp=unconfined --security-opt apparmor=unconfined`.

| id | verdict | severity |
| --- | --- | --- |
| ESCROOT-1 | reproduced | medium |
| ESCROOT-2 | reproduced_not_a_defect | info |
| ESCROOT-3 | reproduced | low |
| ESCROOT-4 | reproduced | low |
| ESCROOT-5 | reproduced | info |

## ESCROOT-1 root reads the kernel's 0400 files: reproduced, medium (documentation)

`docker run $P kcos-audit /bb/busybox sh -c '<for f in ...: stat -c %a; head -c 65536 | wc -c>'`

```
root under init, privileged          uid 1000 under init, privileged
/proc/slabinfo    400  23371 bytes   0 bytes (head: Permission denied)
/proc/vmallocinfo 400  65536         0
/proc/timer_list  400  30703         0
/proc/keys        444  2361 (15 _ses) 136 (1 _ses)
/proc/kpagecount  400  65536         0
/proc/kpageflags  400  65536         0
/proc/kcore, /proc/kmsg  0           0
CapEff: 0000000000000000 in both
```

Control without init (`--entrypoint /bb/busybox`, default Docker options, also with
`--cap-drop ALL`): root reads slabinfo, vmallocinfo, kpagecount and kpageflags too
(Docker does not mask them); timer_list, keys and kcore are masked there. So init
neither adds nor removes read access: the reads follow from uid 0 owning the files.
No escape and no privilege gain. What is wrong is the README: "Root in the container
is an ordinary user to the kernel, even under `--privileged`" and the row title "The
kernel's files are out of reach for root". The row's body is accurate ("cannot open
them for writing"), but nowhere is it said that root still reads them, and the limits
section is silent. Under `--privileged` that includes other containers' keyring names
and timer_list, which Docker's default masking would hide.

## ESCROOT-2 PID 1's limits can be changed, RLIMIT_CPU kills it: reproduced, not a defect, info

```
$ docker run $P kcos-audit-vescape-root-img /aud/esc pid1
prlimit64(1,NOFILE,set soft=7): ok(0)   pid 1 NOFILE after: 7/1048576
sched_setaffinity(1,same mask): ok(0)
setpriority(1, +1): ok(0)               pid 1 nice: before 0, after 1
ioprio_set(pid 1, idle class): ok(0)
$ docker run $P kcos-audit-vescape-root-img /bb/busybox sh -c "trap '' URG; /aud/esc cpukill; echo command finished normally"
prlimit64(1, RLIMIT_CPU, 1s): ok(0)
exit status: 137
```
Same result as the default user (`--user 65534:65534`, no `--privileged`): 137.

Why not a defect: the README promises that PID 1 is opaque (not readable), not that
it cannot be ended, and the outcome is already available to any same-UID process
without touching init:
```
$ docker run --rm --platform linux/arm64 --user 65534:65534 kcos-audit-vescape-root-img /bb/busybox sh -c '/bb/busybox sh -c "kill -9 \$PPID"; echo survived'
exit status: 137
```
A child that SIGKILLs the main command ends the container with the same status 137.
Nothing is gained past the lockdown. Restricting prlimit64 to pid 0 would be cheap
hardening.

## ESCROOT-3 xattrs on program files: reproduced, low

```
$ docker run $P kcos-audit /bb/busybox sh -c '...'
setfattr: /bin/kcontaineros: Permission denied      (before chmod, exit 1)
chmod u+w: 0
setfattr -n user.kcos -v planted /bin/kcontaineros: exit 0
# file: /bin/kcontaineros
user.kcos="planted"
setfattr user.kcos /bb/busybox: exit 0               (no chmod needed)
security.capability: exit 1 (Invalid argument); trusted.x: exit 1 (Operation not permitted)
echo x >> /bin/kcontaineros: Text file busy, exit 1
sha256 dc0f3040...efd60 (same in a fresh container, where getfattr -d shows nothing)
```
As the default user: `setfattr: /bb/busybox: Permission denied`. Root only, contents
unchanged, nothing persists in the image, no privilege. The README sentence "Root can
still change the permissions and timestamps of files it owns" omits extended
attributes, and "nothing can be ... written in those" is not literally true of metadata.

## ESCROOT-4 mq_open fails under init: reproduced, low

```
$ docker run --rm --platform linux/arm64 --user 65534:65534 kcos-audit-vescape-root-img /aud/esc ipc
shmget: ok(0)  msgget: ok(0)  semget: ok(0)
mq_open: errno 13 (Permission denied)
$ ... --entrypoint /aud/esc kcos-audit-vescape-root-img ipc
mq_open: ok(3)
$ docker run $P kcos-audit-vescape-root-img /aud/esc ipc | grep mq
mq_open: errno 13 (Permission denied)
```
README has no mention of message queues. Functional bug: fails closed.

## ESCROOT-5 file capabilities with the effective bit do not start for root: reproduced, info

```
$ docker run $P kcos-audit-vescape-root-img /aud/esc-fcaps caps
kcontaineros: /aud/esc-fcaps: operation not permitted      (same without --privileged)
$ docker run $P --user 1000:1000 ... | grep Cap
CapPrm/CapEff: 0000000000000000   CapBnd: 000001ffffffffff
$ docker run $P --entrypoint /aud/esc-fcaps ... caps
CapEff: 000001ffffffffff          (control)
```
Kernel behaviour with an empty bounding set; fails closed. "File capabilities grant
nothing" holds; the README does not say that for root such a program is refused
rather than run without capabilities.
