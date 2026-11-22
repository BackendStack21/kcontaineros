#!/bin/bash
# What happens when the command is stopped (SIGTSTP, SIGSTOP, SIGTTIN, SIGTTOU),
# without a terminal. Terminal cases are in 04_tty.sh.
cd "$(dirname "$0")"; . ./lib.sh
N=kcos-audit-init-stop-$$
trap 'docker rm -f $N >/dev/null 2>&1' EXIT
start() { docker rm -f $N >/dev/null 2>&1; timeout 60 docker run -d --name $N $P "$@" >/dev/null; }
now() { python3 -c 'import time;print(time.time())'; }
# state of the command (the process whose parent is PID 1 and is not PID 1)
cmdstate() { timeout 30 docker exec $N /bb/busybox sh -c 'for p in /proc/[0-9]*; do s=$(cat $p/stat 2>/dev/null); s=${s##*) }; set -- $s; [ "$2" = 1 ] && echo $1; done' | tr -d '\n'; }
stoptime() { local t0=$(now); timeout 60 docker stop -t 5 $N >/dev/null; python3 -c "import time;print('%.0f'%(time.time()-$t0))"; }

ok "a command that stops itself with SIGTSTP is continued by init" "[99]" "$(r $IMG /bb/kh selfkill 20)"

for s in 20 21 22; do
    start $IMG /bb/busybox sleep 300; sleep 1
    timeout 30 docker kill -s $s $N >/dev/null; sleep 1
    st=$(cmdstate); dt=$(stoptime); rc=$(docker wait $N)
    echo "   docker kill -s $s: command state $st, then docker stop -t 5 took $dt s, exit $rc"
    case $s in
      20) ok "docker kill -s TSTP leaves the command running and stoppable at once" "S 0 143" "$st $dt $rc" ;;
      *)  ok "docker kill -s $s leaves the command running and stoppable at once" "S 0 143" "$st $dt $rc" ;;
    esac
done

# Controls: the same signal with the command as PID 1 (no init), and with Docker's own init.
for how in "--entrypoint /bb/sleep" "--init --entrypoint /bb/sleep"; do
    start $how $IMG 300; sleep 1
    timeout 30 docker kill -s 21 $N >/dev/null; sleep 1
    st=$(timeout 30 docker exec $N /bb/busybox sh -c 'for p in /proc/[0-9]*; do read c < $p/comm; s=$(cat $p/stat); s=${s##*) }; [ "$c" = sleep ] && echo ${s%% *}; done')
    echo "   control ($how): after docker kill -s 21 the sleep is in state $st"
    ok "control ($how): docker kill -s TTIN does not stop the command" "S" "$st"
    docker rm -f $N >/dev/null 2>&1
done

# The command stopped with SIGSTOP by a process inside the container.
start $IMG /bb/busybox sh -c '/bb/busybox sleep 1; kill -STOP $$; echo resumed; /bb/busybox sleep 300'; sleep 2.5
st=$(cmdstate); dt=$(stoptime); rc=$(docker wait $N)
echo "   command stopped itself with SIGSTOP: state $st, docker stop -t 5 took $dt s, exit $rc"
ok "a command stopped by SIGSTOP stays stopped; docker stop needs the SIGKILL" "T 5 137" "$st $dt $rc"

# SIGSTOP sent to the container stops init itself (the kernel does that to
# PID 1 when the signal comes from outside); the command runs on.
start $IMG /bb/kh rec 15; sleep 1
timeout 30 docker kill -s STOP $N >/dev/null; sleep 0.5
init_state=$(timeout 30 docker exec $N /bb/busybox sh -c 's=$(cat /proc/1/stat); s=${s##*) }; echo ${s%% *}')
timeout 30 docker kill -s 10 $N >/dev/null; sleep 0.5
before=$(docker logs $N 2>&1 | tr '\n' ' ')
timeout 30 docker kill -s CONT $N >/dev/null; sleep 0.5
after=$(docker logs $N 2>&1 | tr '\n' ' ')
timeout 30 docker kill -s 15 $N >/dev/null; rc=$(timeout 30 docker wait $N)
ok "docker kill -s STOP stops init; signals wait until CONT and are then forwarded" "T|ready |ready 10 18 |0" "$init_state|$before|$after|$rc"
summary
