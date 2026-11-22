#!/bin/bash
# Signal forwarding by init as PID 1.
cd "$(dirname "$0")"; . ./lib.sh
N=kcos-audit-init-sig-$$
trap 'docker rm -f $N >/dev/null 2>&1' EXIT
wait_ready() { for i in $(seq 1 50); do docker logs $N 2>&1 | grep -q ready && return; sleep 0.1; done; echo "not ready"; }
start() { docker rm -f $N >/dev/null 2>&1; timeout 60 docker run -d --name $N $P "$@" >/dev/null; }

# 1. Every signal but KILL, STOP and CHLD, one at a time, in order; TERM last.
start $IMG /bb/kh rec 15; wait_ready
want=ready; sent=0
for s in $(seq 1 64); do
    case $s in 9|15|17|19) continue ;; esac
    # Docker refuses to send 32 and 33: those come from inside the container.
    case $s in 32|33) timeout 30 docker exec $N /bb/kh sigq 1 $s 1 >/dev/null; sleep 0.3 ;;
               *) timeout 30 docker kill -s $s $N >/dev/null ;; esac
    want="$want
$s"; sent=$((sent+1))
done
timeout 30 docker kill -s 15 $N >/dev/null; sent=$((sent+1))
rc=$(timeout 30 docker wait $N)
ok "$sent signals sent with docker kill arrive at the command, once each, in order" "$want
15[0]" "$(docker logs $N 2>&1)[$rc]"

# 2. SIGCHLD sent to init is not forwarded (it is init's own wake-up).
start $IMG /bb/kh rec 15; wait_ready
timeout 30 docker kill -s CHLD $N >/dev/null; timeout 30 docker kill -s 15 $N >/dev/null
rc=$(timeout 30 docker wait $N)
ok "SIGCHLD sent to init does not reach the command" "ready
15[0]" "$(docker logs $N 2>&1)[$rc]"

# 3. Real-time signals are queued: 1000 of one number sent to PID 1 from
# inside all arrive. Standard signals may merge: at least one arrives.
start $IMG /bb/kh rec 15; wait_ready
timeout 60 docker exec $N /bb/kh sigq 1 40 1000 >/dev/null
timeout 60 docker exec $N /bb/kh sigq 1 64 1000 >/dev/null
timeout 60 docker exec $N /bb/kh sigq 1 10 1000 >/dev/null
sleep 1; timeout 30 docker kill -s 15 $N >/dev/null; rc=$(timeout 30 docker wait $N)
logs=$(docker logs $N 2>&1)
ok "1000 queued signals 40 are all forwarded" 1000 "$(echo "$logs" | grep -c '^40$')"
ok "1000 queued signals 64 are all forwarded" 1000 "$(echo "$logs" | grep -c '^64$')"
n10=$(echo "$logs" | grep -c '^10$')
ok "1000 signals 10 arrive at least once" yes "$([ $n10 -ge 1 ] && echo yes || echo no:$n10)"
echo "   (signal 10 arrived $n10 times of 1000 sent; exit $rc)"

# 4. A signal that is pending before init starts is forwarded to the command.
ok "a signal pending when init starts reaches the command" "10
15[0]" "$(r --entrypoint /bb/kh $IMG presig 10 /bb/kh presig 15 /sbin/init /bb/kh rec 15)"

# 5. A signal ignored by whoever started init is still forwarded.
start --entrypoint /bb/kh $IMG ignoring 15 10 1 -- /sbin/init /bb/kh rec 15; wait_ready
timeout 30 docker kill -s 1 $N >/dev/null; timeout 30 docker kill -s 10 $N >/dev/null; timeout 30 docker kill -s 15 $N >/dev/null
rc=$(timeout 30 docker wait $N)
ok "signals init inherited as ignored are forwarded all the same" "ready
1
10
15[0]" "$(docker logs $N 2>&1)[$rc]"

# 6. SIGTERM right after start, before or during the exec: the container
# ends with 143 every time (default action in the child or in the command).
res=
for i in 1 2 3 4 5 6 7 8 9 10; do
    start $IMG /bb/busybox sleep 60
    timeout 30 docker kill -s TERM $N >/dev/null 2>&1
    res="$res$(timeout 30 docker wait $N) "
done
ok "SIGTERM immediately after docker run -d ends the container with 143, ten times" "143 143 143 143 143 143 143 143 143 143 " "$res"

# 7. docker stop latency, with the command a plain sleep and with a shell-form command.
start $IMG /bb/busybox sleep 300; sleep 1
t0=$(python3 -c 'import time;print(time.time())'); timeout 60 docker stop $N >/dev/null
dt=$(python3 -c "import time;print('%.2f'%(time.time()-$t0))"); rc=$(docker wait $N)
echo "   docker stop of 'sleep 300': $dt s, exit $rc"
ok "docker stop ends sleep 300 with 143 in under a second" "143 yes" "$rc $(python3 -c "print('yes' if $dt<1 else 'no')")"
start kcontaineros sh -c 'sleep 300'; sleep 1
t0=$(python3 -c 'import time;print(time.time())'); timeout 60 docker stop $N >/dev/null
dt=$(python3 -c "import time;print('%.2f'%(time.time()-$t0))"); rc=$(docker wait $N)
echo "   docker stop of sh -c 'sleep 300' (release image): $dt s, exit $rc"
ok "docker stop ends a shell-form sleep with 143 in under a second" "143 yes" "$rc $(python3 -c "print('yes' if $dt<1 else 'no')")"

# 8. Under docker run --init (init is not PID 1). 21 and 22 are left out:
# Docker's own init (tini) keeps SIGTTIN and SIGTTOU to itself.
start --init $IMG /bb/kh rec 15; wait_ready
want=ready
for s in 1 2 3 10 12 14 18 20 28 34 64; do timeout 30 docker kill -s $s $N >/dev/null; want="$want
$s"; done
timeout 30 docker kill -s 15 $N >/dev/null; rc=$(timeout 30 docker wait $N)
ok "under docker run --init signals are forwarded as well" "$want
15[0]" "$(docker logs $N 2>&1)[$rc]"
summary
