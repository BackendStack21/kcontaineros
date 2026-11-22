#!/bin/bash
# Can a process in the container keep PID 1 from noticing that the command
# has ended? Init takes one signal per rt_sigtimedwait, the kernel hands out
# the lowest number first, and SIGCHLD is 17: while one of the signals 1..16
# is pending at every call, the SIGCHLD stays where it is.
#
# The command ignores signals 1..16 (so the forwarded copies do not end it),
# starts NPROC flooders that send them to TARGET for 40 s, and exits 7 after
# one second. TARGET 1 is init; TARGET 999999 does not exist and is the
# control: the same CPU load, no signals. Prints how long the container
# lived. The result depends on how many CPUs the flooders really get, so
# this script measures and compares nothing.
cd "$(dirname "$0")"; . ./lib.sh
N=kcos-audit-init-flood-$$
trap 'docker rm -f $N >/dev/null 2>&1' EXIT
SIGS="1 2 3 4 5 6 7 8 10 11 12 13 14 15 16"
run() { # TARGET NPROC
    docker rm -f $N >/dev/null 2>&1
    local t0=$(python3 -c 'import time;print(time.time())')
    timeout 120 docker run -d --name $N $P --pids-limit 120 --memory 128m $IMG \
        /bb/kh ignoring $SIGS -- /bb/busybox sh -c "/bb/kh flood $1 $2 40 $SIGS; /bb/kh sleepms 1000; exit 7" >/dev/null
    local rc=$(timeout 100 docker wait $N)
    echo "   target $1, $2 flooders: container ended with $rc after $(python3 -c "import time;print('%.1f'%(time.time()-$t0))") s"
}
run 999999 90; run 999999 90; run 999999 90
run 1 4; run 1 40
run 1 90; run 1 90; run 1 90; run 1 90; run 1 90
# Rates: how fast four flooders send and how fast init forwards.
docker rm -f $N >/dev/null 2>&1
timeout 60 docker run --rm --name $N $P -e KH_VERBOSE=1 --pids-limit 100 --memory 128m $IMG \
    /bb/kh ignoring $SIGS -- /bb/busybox sh -c "/bb/kh flood 1 4 5 $SIGS; exec /bb/kh tally 4" 2>&1 | sed 's/^/   /'
