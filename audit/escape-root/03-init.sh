#!/bin/bash
# PID 1 as a target, what the command inherits from it, and what processes
# started with `docker exec` get. Run from the repo root after build.sh.
. "$(dirname "$0")/lib.sh"
N=kcos-audit-escape-root-c$$
trap 'docker rm -f $N >/dev/null 2>&1' EXIT

section "descriptors, environment and signal state the command inherits: under init"
init $BB sh -c "$BB ls -l /proc/self/fd; $BB env; $BB grep -E 'Sig(Blk|Ign|Cgt)|PPid|NSpid' /proc/self/status; $BB cat /proc/self/loginuid; echo; $BB cat /proc/self/oom_score_adj; $BB grep -E 'open files|core|processes' /proc/self/limits"
section "the same: control"
ctl $BB sh -c "$BB ls -l /proc/self/fd; $BB env; $BB grep -E 'Sig(Blk|Ign|Cgt)|PPid|NSpid' /proc/self/status"

section "PID 1 as a target: under init"
init /aud/esc pid1
init $BB sh -c "$BB cat /proc/1/status | $BB grep -E 'Name|State|Cap|NoNew|Seccomp|SigBlk|SigCgt'; $BB cat /proc/1/cmdline | $BB tr '\\0' ' '; echo; $BB cat /proc/1/limits | $BB head -4"
section "PID 1 as a target: control (PID 1 is a busybox shell, the helper its child)"
ctl $BB sh -c "/aud/esc pid1; echo shell-still-here"

section "signals sent to init from inside are forwarded to the command"
# The command traps TERM and USR1; a grandchild signals PID 1.
init $BB sh -c "trap 'echo command got TERM' TERM; trap 'echo command got USR1' USR1; ($BB kill -USR1 1; $BB kill -TERM 1; $BB kill -KILL 1; $BB kill -STOP 1) ; $BB sleep 1; $BB grep State /proc/1/status; echo command still running"
echo "exit status of the container: $?"

section "RLIMIT_CPU set on PID 1 by the command, then a flood of signals for init to forward"
init $BB sh -c "trap '' URG; /aud/esc cpukill; echo command finished normally"
echo "exit status of the container: $?"

section "the command stops itself (SIGSTOP): does the container hang?"
timeout 20 docker run --rm --name $N $PLAT $PRIV "$IMG" $BB sh -c "$BB kill -STOP \$\$; echo resumed"; echo "docker run ended with $? (124 = still stopped after 20 s)"
docker rm -f $N >/dev/null 2>&1

section "docker exec: what a process started outside init gets, and what the workload can do to it"
docker rm -f $N >/dev/null 2>&1
timeout 120 docker run -d --rm --name $N $PLAT $PRIV "$IMG" $BB sh -c "$BB sleep 4; for p in /proc/[0-9]*; do echo \"workload sees \$p: \$($BB cat \$p/cmdline 2>/dev/null | $BB tr '\\0' ' ')\"; /aud/esc rd \$p/environ \$p/mem \$p/root \$p/fd; /aud/esc wr \$p/mem; done; $BB sleep 25" >/dev/null
sleep 1
echo "-- docker exec /bin/sh (kContainerOS shell):"
timeout 30 docker exec $N /bin/sh -c '/bb/busybox grep -E "Cap(Prm|Eff|Bnd)|NoNew|Seccomp:" /proc/self/status; /aud/esc wr /proc/sys/kernel/hostname /bin/kcontaineros; /aud/esc sys' 2>&1 | grep -E 'Cap|NoNew|Seccomp|append|memfd_create|mount\(|unshare|bpf|io_uring_setup'
echo "-- docker exec /bb/busybox (not a kContainerOS program):"
timeout 30 docker exec $N $BB sh -c "$BB grep -E 'Cap(Prm|Eff|Bnd)|NoNew|Seccomp:' /proc/self/status; /aud/esc wr /proc/sys/kernel/hostname /bin/kcontaineros; /aud/esc sys" 2>&1 | grep -E 'Cap|NoNew|Seccomp|append|memfd_create|mount\(|unshare|bpf|io_uring_setup'
echo "-- a docker exec process that lives while the workload looks at it:"
timeout 30 docker exec -e SECRET_OF_EXEC=1 $N $BB sleep 6 &
sleep 7
timeout 30 docker logs $N 2>&1
docker rm -f $N >/dev/null 2>&1
wait
