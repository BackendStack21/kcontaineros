#!/bin/bash
# Zombie reaping as PID 1, and what a nested init (not PID 1) does with
# what the command leaves behind.
cd "$(dirname "$0")"; . ./lib.sh
L="--pids-limit 300 --memory 256m"

ok "5000 short-lived orphans are all reaped (PID 1)" "orphans made: 5000
0[0]" "$(r $L $IMG /bb/busybox sh -c '/bb/kh orphans 5000 0; /bb/kh sleepms 500; /bb/kh count Z')"
ok "250 orphans alive at once, all reaped after they exit (PID 1)" "orphans made: 250
0[0]" "$(r $L $IMG /bb/busybox sh -c '/bb/kh orphans 250 400; /bb/kh sleepms 1500; /bb/kh count Z')"
ok "20000 orphans under docker run --init (init as subreaper)" "orphans made: 20000
0[0]" "$(r $L --init $IMG /bb/busybox sh -c '/bb/kh orphans 20000 0; /bb/kh sleepms 500; /bb/kh count Z')"

t0=$(python3 -c 'import time;print(time.time())')
out=$(r $L $IMG /bb/busybox sh -c '/bb/kh stubborn 100 setsid; /bb/kh stubborn 100 & /bb/busybox sleep 100 & kill -STOP $!; /bb/kh hopper 100 & /bb/kh sleepms 300; exit 5')
dt=$(python3 -c "import time;print('yes' if time.time()-$t0<3 else 'no')")
ok "PID 1: the container ends with the command's status at once, whatever is left behind" "[5] yes" "$out $dt"

# Nested: the outer PID 1 is a busybox shell without init. It runs init, then
# reports init's status, how long it took, and which helper processes are left.
nested() { r $L --entrypoint /bb/busybox "$@" $IMG sh -c '
    t0=$(/bb/kh now); /sbin/init -- /bb/busybox sh -c "$1"; rc=$?; t1=$(/bb/kh now)
    /bb/kh sleepms 200
    left=0; for p in /proc/[0-9]*; do read c < $p/comm 2>/dev/null || continue; case $c in kh|sleep|"x) S 1 1 1 (") left=$((left+1));; esac; done
    echo "status $rc after $(( (t1-t0+250)/500*500 )) ms, $left left"' sh "$NESTED"; }
NESTED='exit 5'
ok "nested: nothing left behind" "status 5 after 0 ms, 0 left[0]" "$(nested)"
NESTED='/bb/busybox sleep 100 & /bb/busybox setsid /bb/busybox sleep 100 & /bb/kh sleepms 200; exit 5'
ok "nested: leftovers that die of SIGTERM, one in another session" "status 5 after 0 ms, 0 left[0]" "$(nested)"
NESTED='/bb/busybox sleep 100 & kill -STOP $!; /bb/kh sleepms 200; exit 5'
ok "nested: a stopped leftover is continued and ends" "status 5 after 0 ms, 0 left[0]" "$(nested)"
NESTED='/bb/kh stubborn 100 setsid; /bb/kh stubborn 100 & /bb/kh sleepms 200; exit 5'
ok "nested: leftovers ignoring SIGTERM are killed after 2 s" "status 5 after 2000 ms, 0 left[0]" "$(nested)"
NESTED='/bb/kh stubborn 100 setsid name "x) S 1 1 1 ("; "/bb/x) S 1 1 1 (" stubborn 100 & /bb/kh sleepms 200; exit 5'
ok "nested: leftovers named 'x) S 1 1 1 (' are found and killed" "status 5 after 2000 ms, 0 left[0]" "$(nested)"
NESTED='/bb/busybox sh -c "trap \"\" TERM; /bb/kh stubborn 100; :" & /bb/kh sleepms 200; exit 5'
ok "nested: the child of a killed leftover is killed in the next round" "status 5 after 2000 ms, 0 left[0]" "$(nested)"
NESTED='/bb/kh stubborn 100 setsid; (trap "" TERM; /bb/kh stubborn 1; kill -USR1 $PPID) & /bb/kh sleepms 200; exit 5'
ok "nested: a signal sent to init during the 2 s ends the wait" "status 5 after 1000 ms, 0 left[0]" "$(nested)"
NESTED='/bb/kh hopper 100 & /bb/kh hopper 100 & /bb/kh hopper 100 & /bb/kh sleepms 200; exit 5'
ok "nested: three leftovers that fork, exit and change session in a loop are killed" "status 5 after 2000 ms, 0 left[0]" "$(nested)"
# The outer shell's own child is not init's business.
ok "nested: a process that is not a descendant of init is left alone" "status 0 after 0 ms, 1 left[0]" \
   "$(r $L --entrypoint /bb/busybox $IMG sh -c '/bb/kh stubborn 100 & t0=$(/bb/kh now); /sbin/init -- /bb/busybox true; rc=$?; t1=$(/bb/kh now)
    left=0; for p in /proc/[0-9]*; do read c < $p/comm 2>/dev/null || continue; case $c in kh) left=$((left+1));; esac; done
    echo "status $rc after $(( (t1-t0+250)/500*500 )) ms, $left left"')"
# Processes that were children of init before the command existed (started
# by whatever exec'ed init) are treated as leftovers too.
ok "nested: children init inherited from the program that exec'ed it survive the command" "init status 0, 2 left[0]" \
   "$(r $L --entrypoint /bb/busybox $IMG sh -c '/bb/busybox sh -c "/bb/kh stubborn 30 & /bb/busybox sleep 30 & exec /sbin/init -- /bb/busybox true"; rc=$?
    left=0; for p in /proc/[0-9]*; do read c < $p/comm 2>/dev/null || continue; case $c in kh|sleep) left=$((left+1));; esac; done; echo "init status $rc, $left left"')"

# A fork bomb of signal-ignoring processes, held at 300 by the pids limit:
# init gives up. Timed from outside, because the outer shell cannot fork.
t0=$(python3 -c 'import time;print(time.time())')
out=$(r $L --cpus 2 --entrypoint /bb/busybox $IMG sh -c '/sbin/init -- /bb/busybox sh -c "/bb/kh bomb 14 & /bb/kh sleepms 300; exit 5"; echo "status $?"; n=0; for p in /proc/[0-9]*; do n=$((n+1)); done; echo "$n processes left"')
dt=$(python3 -c "import time;print('%.1f'%(time.time()-$t0))")
echo "   nested, fork bomb as leftover: $(echo "$out" | tr '\n' ' ') after $dt s in all (the bomb ends itself after 14 s)"

# /proc of another PID namespace: init is in a new namespace (unshare -p),
# /proc still shows the outer one, so PIDs read there mean nothing.
NESTED='/bb/kh stubborn 100 setsid; /bb/kh stubborn 100 & /bb/kh sleepms 200; exit 5'
echo "   nested in a new PID namespace with the outer /proc: $(r $L --privileged --entrypoint /bb/busybox $IMG unshare -p -f /bb/busybox sh -c '
    /bb/kh stubborn 30 & t0=$(/bb/kh now); /sbin/init -- /bb/busybox sh -c "$1"; rc=$?; t1=$(/bb/kh now)
    echo "status $rc after $(( (t1-t0+250)/500*500 )) ms"; /bb/kh sleepms 200; /bb/busybox ps -o pid,ppid,comm | /bb/busybox grep -c "kh$"' sh "$NESTED" | tr '\n' ' ')"

# docker run --init: Docker's init is PID 1, this one its child. docker stop
# with a leftover that ignores SIGTERM takes the documented 2 s.
N=kcos-audit-init-reap-$$
timeout 60 docker run -d --init --name $N $P $IMG /bb/busybox sh -c '/bb/kh stubborn 100 setsid; exec /bb/kh rec 15' >/dev/null; sleep 1
t0=$(python3 -c 'import time;print(time.time())'); timeout 60 docker stop $N >/dev/null
dt=$(python3 -c "import time;print('%.0f'%(time.time()-$t0))"); rc=$(docker wait $N); docker rm -f $N >/dev/null 2>&1
ok "under docker run --init, docker stop with a stubborn leftover takes 2 s and gives the command's status" "2 0" "$dt $rc"

# Shared PID namespace with another container (--pid=container:X).
A=kcos-audit-init-pidns-$$
timeout 60 docker run -d --rm --name $A $P --entrypoint /bb/busybox $IMG sleep 60 >/dev/null
out=$(r $L --pid=container:$A $IMG /bb/busybox sh -c '/bb/kh stubborn 100 setsid; /bb/kh sleepms 200; echo "init is $PPID"; exit 5')
left=$(timeout 30 docker exec $A /bb/busybox ps -o pid,comm | grep -cE 'kh|init')
alive=$(docker inspect -f '{{.State.Running}}' $A)
docker rm -f $A >/dev/null 2>&1
ok "in another container's PID namespace: leftovers killed, the other container untouched" "[5] 0 true" "[${out##*[} $left $alive"
echo "   ($out)"
summary
