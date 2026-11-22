#!/bin/bash
# Goal: make init report a wrong exit status, hang or exhaust it, hide
# processes from the cleanup at exit, survive `docker stop`, and steer init
# through environment variables only.
. "$(dirname "$0")/lib.sh"
trap cleanup_names EXIT
ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
st() {  # NAME WANT_STATUS args... : run, compare the exit status
  local name=$1 want=$2; shift 2
  local out; out=$("$@" 2>&1); local got=$?
  if [ "$got" = "$want" ]; then ok "$name: exit status $got"; else bad "$name: exit status $got, expected $want"; show "$out"; fi
}
echo "## exit status pass-through (the command is busybox sh unless said)"
st "exit 0"        0   $D $NOBODY $IMG sh -c 'exit 0'
st "exit 7"        7   $D $NOBODY $IMG sh -c 'exit 7'
st "exit 255"      255 $D $NOBODY $IMG sh -c 'exit 255'
st "killed by KILL" 137 $D $NOBODY $IMG sh -c 'kill -KILL $$'
st "killed by TERM" 143 $D $NOBODY $IMG sh -c 'kill -TERM $$'
st "killed by SEGV" 139 $D $NOBODY $IMG sh -c 'kill -SEGV $$'
st "command not found" 127 $D $NOBODY $IMG no-such-command
st "command not executable" 126 $D $NOBODY $IMG /etc/passwd
st "status of the command, not of a later orphan" 3 $D $NOBODY $IMG sh -c '(sleep 0.3; exit 9) & exit 3'
st "status of the command, not of an earlier child" 4 $D $NOBODY $IMG sh -c '(exit 9) & sleep 0.3; exit 4'

echo "## signals sent to PID 1 from inside, as the same user"
st "SIGKILL and SIGSTOP to PID 1 do nothing" 5 $D $NOBODY $IMG sh -c 'kill -KILL 1; kill -STOP 1; sleep 0.3; exit 5'
st "5000 signals to PID 1 (forwarded to a command that ignores them)" 6 $D $NOBODY $IMG sh -c 'trap "" USR1 USR2; i=0; while [ $i -lt 2500 ]; do kill -USR1 1; kill -USR2 1; i=$((i+1)); done; exit 6'
st "SIGCHLD storm and 2000 orphans to reap" 8 $D $NOBODY --pids-limit 256 $IMG sh -c 'i=0; while [ $i -lt 2000 ]; do (true &) ; kill -CHLD 1; i=$((i+1)); done; exit 8'
out=$($D $NOBODY $IMG sh -c 'kill -TERM 1; sleep 3; echo SURVIVED' 2>&1); got=$?
note "SIGTERM sent to PID 1 by a workload process is forwarded to the command: exit $got ($out)"

echo "## leftovers at exit, init as PID 1: setsid, double fork, own group, stopped, ignoring SIGTERM"
LEFT='trap "" TERM HUP; setsid sh -c "trap \"\" TERM HUP; sleep 31337 & sleep 31337" & (setsid setsid sleep 31337 &) ; sleep 31337 & kill -STOP $! ; sleep 0.5; exit 3'
a=$(ms); out=$($D $NOBODY --name $T-left-$$ $IMG sh -c "$LEFT" 2>&1); got=$?; b=$(ms)
left=$(docker ps -a --filter name=$T-left-$$ -q | wc -l | tr -d ' ')
echo "  exit $got after $((b-a)) ms, containers left: $left"
if [ "$got" = 3 ] && [ "$left" = 0 ]; then ok "PID 1: exit status 3, the container ends with 5 leftovers in other sessions/groups"; else bad "leftovers at exit"; show "$out"; fi

echo "## the same with --pid host (init is not PID 1 and has to clean up itself)"
a=$(ms); out=$($D $NOBODY --pid host --pids-limit 64 --memory 64m $IMG sh -c "$LEFT" 2>&1); got=$?; b=$(ms)
sleep 1
surv=$($D --pid host $CTL $IMG sh -c 'ps -o pid,user,args | grep "sleep 31337" | grep -v grep' 2>&1)
echo "  exit $got after $((b-a)) ms; survivors: [$surv]"; show "$out"
if [ "$got" = 3 ] && [ -z "$surv" ]; then ok "--pid host: exit status 3, no 'sleep 31337' left on the host's process list"; else bad "--pid host: leftovers survive or status wrong"; fi

echo "## --pid host, leftovers that change PID every millisecond (4 chains, 20 s, ignore SIGTERM)"
a=$(ms); out=$($D $NOBODY --pid host --pids-limit 64 --memory 64m $IMG sh -c 'kp churn 20; kp churn 20; kp churn 20; kp churn 20; sleep 0.2; exit 4' 2>&1); got=$?; b=$(ms)
sleep 1
surv=$($D --pid host $CTL $IMG sh -c 'ps -o pid,user,args | grep "kp churn" | grep -v grep' 2>&1)
echo "  exit $got after $((b-a)) ms; survivors: [$(echo "$surv" | tr '\n' ';')]"; show "$out"
if [ "$got" = 4 ] && [ -z "$surv" ]; then ok "--pid host: PID-churning leftovers are gone after the container exits, status 4"; else bad "--pid host: PID-churning leftovers survive the container or change its status"; fi

echo "## --pid host: the default user can kill init itself (it is not PID 1 there)"
out=$($D $NOBODY --pid host $IMG sh -c 'kill -KILL $PPID; sleep 2; echo STILL-RUNNING; exit 0' 2>&1); got=$?
note "--pid host: kill -KILL of init from the command gives exit status $got (output: [$out])"

echo "## docker stop"
stop() {  # NAME script -> prints time and status
  local name=$1 script=$2 c=$T-stop-$$
  docker run -d --platform linux/arm64 $NOBODY --name $c $IMG sh -c "$script" >/dev/null
  sleep 1.5
  local a b; a=$(ms); timeout 60 docker stop -t 3 $c >/dev/null; b=$(ms)
  local code; code=$(docker inspect -f '{{.State.ExitCode}} running={{.State.Running}}' $c)
  docker rm -f $c >/dev/null
  echo "  $name: stopped in $((b-a)) ms, exit $code"
  STOP_MS=$((b-a)); STOP_CODE=$code
}
stop "sleep" 'exec sleep 300'
[ $STOP_MS -lt 1500 ] && [ "$STOP_CODE" = "143 running=false" ] && ok "docker stop reaches the command at once (143)" || bad "docker stop on sleep"
stop "command and orphans ignore SIGTERM" 'trap "" TERM; (setsid sh -c "trap \"\" TERM; sleep 300" &); while :; do sleep 1; done'
[ $STOP_MS -lt 6000 ] && [ "$STOP_CODE" = "137 running=false" ] && ok "a command that ignores SIGTERM is killed when the timeout ends (137), nothing survives" || bad "docker stop on TERM-ignoring command"
stop "command stopped itself (SIGSTOP)" 'kill -STOP $$; sleep 300'
[ "$STOP_CODE" = "137 running=false" ] && note "a command that is stopped (SIGSTOP, by itself or by a child) does not act on docker stop: it takes the whole timeout ($STOP_MS ms) and ends with 137, like one that ignores SIGTERM"

echo "## environment only (docker run -e): PATH, KCOS_EXEC, LD_*, shell variables"
V=$T-vol3-$$; docker volume create $V >/dev/null
$D $CTL -v $V:/data $IMG sh -c 'cp /opt/evil /data/myapp; chmod 755 /data/myapp; printf "echo RC-FILE-RAN\n" > /data/rc; chown -R 65534:65534 /data'
st "PATH=/data makes init look for the command on a volume: refused" 126 $D $NOBODY -v $V:/data -e PATH=/data $IMG myapp
st "LD_PRELOAD, LD_LIBRARY_PATH, LD_AUDIT pointing at a written file change nothing" 0 $D $NOBODY -v $V:/data -e LD_PRELOAD=/data/myapp -e LD_LIBRARY_PATH=/data -e LD_AUDIT=/data/myapp $IMG /bin/true
out=$($D $NOBODY -v $V:/data -e ENV=/data/rc -e BASH_ENV=/data/rc -e IFS=: -e PS1='PS1-USED' -e PS4='PS4-USED' -e HOME=/data -e PWD=/nonexistent -e OLDPWD=/data -e SHELLOPTS=xtrace -e CDPATH=/data $IMG /bin/sh -c 'X=a:b; /bin/echo $X; /bin/echo "$PWD"; set -x; cd; /bin/pwd' 2>&1)
show "$out"
want=$'+ /bin/pwd\n+ cd\n/\n/data\na:b'   # sorted: stdout and stderr arrive in either order
[ "$(echo "$out" | LC_ALL=C sort)" = "$want" ] && ok "ENV, BASH_ENV, IFS, PS1, PS4, PWD, SHELLOPTS, CDPATH do not steer the shell (HOME is where cd goes)" || bad "a shell variable from the environment changed the shell's behaviour"
out=$($D $NOBODY -e KCOS_EXEC=/dev/shm:/proc/self/root/tmp:/sys/fs $IMG sh -c 'cp /opt/evil /dev/shm/evil; chmod 755 /dev/shm/evil; /dev/shm/evil; echo "exec=$?"' 2>&1); show "$out"
echo "$out" | grep -q 'exec=126' && [ "$(echo "$out" | grep -c 'cannot hold programs: ignored')" = 3 ] && ok "KCOS_EXEC cannot name /dev/shm, /proc or /sys" || bad "KCOS_EXEC accepted a kernel directory"
out=$($D $NOBODY -v $V:/data -e KCOS_EXEC=/data -e PATH=/data $IMG myapp 2>&1); got=$?; show "$out"
echo "$out" | grep -q EVIL-BINARY-RAN && note "by design: whoever sets the environment names the program directories. KCOS_EXEC=/data on a volume a previous run wrote to starts what that run wrote (exit $got)"
summary
