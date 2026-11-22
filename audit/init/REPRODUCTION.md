# Independent reproduction of the "init" findings

Reviewer run of 22 Nov 2026 against `kcontaineros` 0.2.0 and `kcos-audit`.
The auditor's helper image was gone, so `kh.c` was rebuilt unchanged into
`kcos-audit-vinit-img` (`kcos-audit` plus `/bb/kh`), which was removed
afterwards. Containers were named `kcos-audit-vinit-*`. Docker VM: 10 CPUs.

| ID | Verdict | Severity |
|---|---|---|
| INIT-1 | reproduced | low |
| INIT-2 | reproduced (stronger than reported) | low |
| INIT-3 | reproduced | low |
| INIT-4 | reproduced | low |
| INIT-5 | reproduced | info |

## INIT-1: forwarded SIGTTIN/SIGTTOU stops the command for good

`docker run -d kcos-audit /bb/busybox sleep 300`, `docker kill -s SIG`,
process states from `/proc/*/stat` via `docker exec`, then `docker stop -t 5`:

```
init, TSTP: init:S busybox:S busybox:S
  stop took 0.1 s, exit 143
init, TTIN: init:S busybox:T busybox:S
  stop took 5.2 s, exit 137
init, TTOU: init:S busybox:T busybox:S
  stop took 5.1 s, exit 137
control --entrypoint /bb/sleep, TTIN: sleep:S busybox:S
  stop took 5.1 s, exit 137        (sleep as PID 1 ignores SIGTERM; unrelated)
control --init --entrypoint /bb/sleep, TTIN: docker-init:S sleep:S busybox:S
  stop took 0.1 s, exit 143
release image (kcontaineros sleep 300), TTIN:
  stop took 5.1 s, exit 137
self SIGSTOP (sh -c 'sleep 1; kill -STOP $$; ...'): init:S busybox:T busybox:S
  stop took 5.2 s, exit 137
```

The README has nothing on this: it says `docker stop` reaches the command at
once (line 215) and explains only Ctrl-Z (line 447). `src/init.rs:125`
continues the command only after a stop by SIGTSTP. Low: it needs someone
to send a stop signal to the container, or a process of the same user in
it, and the result is a slow `docker stop` with status 137.

## INIT-2: signals 1..16 sent to PID 1 keep init from seeing SIGCHLD

`docker run -d --pids-limit 120 --memory 128m kcos-audit-vinit-img /bb/kh
ignoring $S -- /bb/busybox sh -c "/bb/kh flood TARGET N SECS $S; /bb/kh
sleepms 1000; exit 7"`, time until `docker wait` returns:

```
target 999999, 90 flooders: container ended with 7 after 1.3 s   (x6, all 1.3 s)
target 1, 90 flooders: container ended with 7 after 40.4 s, 40.0, 39.9, 39.9, 39.9, 40.0
target 1, 90 flooders for 15 s: container ended with 7 after 14.9 s
  at 4 s: pid1=init; command stat: 7 (busybox) Z
target 1, 90 flooders for 25 s: container ended with 7 after 24.9 s
target 1, 4 flooders for 20 s: container ended with 7 after 19.9 s
target 1, 20 flooders for 20 s: container ended with 7 after 19.9 s
target 1, 40 flooders for 20 s: container ended with 7 after 20.0 s
1 flooder for 20 s: ended with 7 after 1.2 s
docker stop -t 3 during a 4-flooder flood (command already a zombie): took 3.1 s, exit 137
```

On this run the effect was not a delay of a few seconds, as reported, but
complete: with four or more flooders the container lived exactly as long as
the flood, in every run, with the command a zombie. One flooder was not
enough. `docker stop` then needs its SIGKILL. Still low: sender and init are
the same user, who could as well stop the command with SIGSTOP (INIT-1);
nothing is gained past the lockdown. It is the cheapest of the five to fix.

## INIT-3: nested init signals a reused PID

Same scenario as `07_pid_reuse.sh` (outer PID 1 is busybox sh, no init):

```
== control (WRAP=0)
init is 400, its command is 401
leader: pid 404 pgid 404 ppid 1
leader: survived
bystander ended with status 0
init ended with status 5
== with PID reuse (WRAP=1)            (4 min 20 s)
init is 400, its command is 401
wrap: 4193999 forks, next pid is 400
leader: pid 401 pgid 401 ppid 1
bystander ended with status 137
Killed
init ended with status 5
```

`src/init.rs:213` sends to `-child` on every round after the command has
been reaped. Low: nested mode only, a wrapped PID counter, a leftover
outside the group, and the victim is a process the same user could kill
anyway.

## INIT-4: nested init kills children it inherited

```
$ docker run --rm --entrypoint /bb/busybox kcos-audit-vinit-img sh -c '/bb/busybox sh -c "/bb/kh stubborn 30 & /bb/busybox sleep 30 & exec /sbin/init -- /bb/busybox true"; echo "init status $?"; /bb/busybox ps -o pid,ppid,comm'
init status 0
PID   PPID  COMMAND
    1     0 busybox
real 0m2.252s

control, exec /bb/busybox true instead of init:
status 0
    1     0 busybox
    8     1 kh
    9     1 busybox

control, init as a child of the shell that started the helpers (siblings, not children):
init status 0
    1     0 busybox
    7     1 kh
    8     1 busybox
```

The README row (line 459) says "stops what the command left behind"; these
were not left by the command. Low, and arguably a matter of wording.

## INIT-5: nested init gives up; README states no limit

(a) `--pids-limit 300 --memory 256m --cpus 2`, `/bb/kh bomb 14` as leftover,
three runs:

```
kcontaineros: warning: some processes could not be stopped
status 5
298 processes left      8.7 s in all
... 279 processes left  8.6 s in all
... 289 processes left  8.6 s in all
```

Baseline, one SIGTERM-ignoring leftover in another session: `status 5 after
2007 ms`, nothing left.

(b) `--privileged --entrypoint /bb/busybox ... unshare -p -f /bb/busybox sh
-c '/sbin/init -- ...'` (the /proc is the outer namespace's):

```
kcontaineros: warning: some processes could not be stopped
status 5 after 2209 ms
PID   PPID  COMMAND
    1     0 busybox
    7     1 busybox
   12     7 kh
```

Control without `unshare`: `status 5 after 2206 ms`, no warning, no `kh`
left. Neither limit is in README.md or docs/llms.txt (`grep -i 'could not be
stopped\|give up'` finds nothing relevant). Deliberate in the code
(`GIVE_UP_MS`, the /proc/self test) and announced on stderr: info.
