#!/bin/bash
# Unusual starts: fork failing, standard descriptors closed or full, PATH
# variants, big argument lists, init inside init, the sealed image.
cd "$(dirname "$0")"; . ./lib.sh
N=kcos-audit-init-misc-$$
trap 'docker rm -f $N >/dev/null 2>&1' EXIT
BB="--entrypoint /bb/busybox"

ok "fork fails (--pids-limit 1): a message and status 1" "kcontaineros: fork: resource temporarily unavailable[1]" "$(r --pids-limit 1 $IMG /bb/kh exit 3)"

# Standard descriptors.
ok "stdin, stdout and stderr closed: the status still comes through" "[3]" "$(r --entrypoint /bb/kh $IMG closefd 012 /sbin/init /bb/kh exit 3)"
ok "all three closed and the command missing: 127, silently" "[127]" "$(r --entrypoint /bb/kh $IMG closefd 012 /sbin/init /bb/nothing)"
ok "all three closed and a KCOS_EXEC entry to warn about" "[3]" "$(r -e KCOS_EXEC=/bb:/nonexistent:relative --entrypoint /bb/kh $IMG closefd 012 /sbin/init /bb/kh exit 3)"
ok "only stderr closed and a KCOS_EXEC entry to warn about: nothing lands on stdout" "[3]" "$(r -e KCOS_EXEC=/bb:/nonexistent:relative --entrypoint /bb/kh $IMG closefd 2 /sbin/init /bb/kh exit 3)"
ok "stderr is /dev/full and the command is missing" "[127]" "$(r $BB $IMG sh -c 'exec /sbin/init /bb/nothing 2>/dev/full')"
ok "stdout is /dev/full" "[3]" "$(r $BB $IMG sh -c 'exec /sbin/init /bb/kh exit 3 >/dev/full')"
ok "stderr is a closed pipe and there is a warning to print: no SIGPIPE reaches the command" "ready
15[0]" "$(r -e KCOS_EXEC=/bb:relative $BB $IMG sh -c '{ /sbin/init /bb/busybox sh -c "/bb/kh rec 15 2>/dev/null & p=\$!; /bb/kh sleepms 300; kill -15 \$p; wait \$p" 2>&1 >&3 | /bb/busybox true; } 3>&1')"

# PATH.
ok "no PATH in the environment: the default one" "[0]" "$(r $BB $IMG env -i KCOS_EXEC=/bb /sbin/init true)"
ok "empty environment" "[4]" "$(r $BB $IMG env -i /sbin/init /bin/kcontaineros sh -c 'exit 4')"
ok "PATH empty means the current directory: not found in /" "kcontaineros: true: no such file or directory[127]" "$(r -e PATH= $IMG true)"
ok "PATH empty means the current directory: found in /bin" "[0]" "$(r -e PATH= -w /bin $IMG true)"
ok "relative PATH entry" "[0]" "$(r -e PATH=bin $IMG true)"
ok "PATH entry that is a file is skipped" "[0]" "$(r -e PATH=/bb/kh:/bin $IMG true)"
ok "PATH entry that does not exist is skipped" "[0]" "$(r -e PATH=/nonexistent:/bin $IMG true)"
ok "PATH entry of 5000 bytes is skipped" "[0]" "$(r -e PATH=/$(printf 'd%.0s' $(seq 1 5000)):/bin $IMG true)"
ok "PATH entry that cannot be searched is skipped when a later one has the program" "[0]" "$(r -e PATH=/bb/locked:/bin $IMG true)"
ok "program only in a directory that cannot be searched: 126" "kcontaineros: khx: permission denied[126]" "$(r -e PATH=/bb/locked:/bin $IMG khx)"
ok "a non-executable file earlier in PATH does not hide the program" "[0]" "$(r -e PATH=/bb/p1:/bin $IMG true)"
ok "only a non-executable file in PATH: 126" "kcontaineros: true: permission denied[126]" "$(r -e PATH=/bb/p1 $IMG true)"
ok "a text file without #! found in PATH ends the search (init has no shell to hand it to)" "kcontaineros: echo: exec format error[126]" "$(r -e PATH=/bb/p1:/bin $IMG echo hi)"

# Arguments.
big=$(printf 'A%.0s' $(seq 1 100000))
ok "one argument of 100000 bytes" "[3]" "$(r $IMG /bb/kh exit 3 $big)"
ok "5000 arguments" "script ran 5000[0]" "$(r $IMG /bb/script $(seq 1 5000))"
ok "init started with an argument list at the kernel's limit passes it on" "bigexec: N bytes of padding
script ran N[0]" "$(r --entrypoint /bb/kh $IMG bigexec /sbin/init /bb/script | sed 's/[0-9][0-9]* bytes/N bytes/;s/ran [0-9]*/ran N/')"

# Init inside init, and under other names.
ok "init as the command of init" "[9]" "$(r $IMG /sbin/init /sbin/init -- /bb/kh exit 9)"
ok "kcontaineros init CMD" "[9]" "$(r $IMG /bin/kcontaineros init /bb/kh exit 9)"
ok "kcontaineros init as the entry point (PID 1)" "1[0]" "$(r --entrypoint /bin/kcontaineros $IMG init /bb/busybox sh -c 'echo $PPID')"
docker rm -f $N >/dev/null 2>&1
timeout 60 docker run -d --name $N $P $IMG /sbin/init /sbin/init /bb/kh rec 15 >/dev/null; sleep 1
for s in 10 12 34; do timeout 30 docker kill -s $s $N >/dev/null; done
t0=$(python3 -c 'import time;print(time.time())'); timeout 60 docker stop $N >/dev/null
dt=$(python3 -c "import time;print('yes' if time.time()-$t0<1 else 'no')"); rc=$(docker wait $N)
ok "three inits deep: signals arrive and docker stop takes under a second" "ready
10
12
34
15[0] yes" "$(docker logs $N 2>&1)[$rc] $dt"

# The sealed image (init only) with the helper as its program.
S=kcos-audit-init-sealed
ok "sealed: exit status" "[42]" "$(r $S kh exit 42)"
ok "sealed: killed by SIGSEGV" "[139]" "$(r $S kh selfkill 11)"
ok "sealed: missing command" "kcontaineros: nothing: no such file or directory[127]" "$(r $S nothing)"
ok "sealed: started under any name it is init" "[42]" "$(r --entrypoint /usr/local/bin/kh $S closefd 9 /sbin/init kh exit 42)"
docker rm -f $N >/dev/null 2>&1
timeout 60 docker run -d --name $N $P $S kh rec 15 >/dev/null; sleep 1
for s in 1 2 10 64; do timeout 30 docker kill -s $s $N >/dev/null; done
timeout 60 docker stop $N >/dev/null; rc=$(docker wait $N)
ok "sealed: signals are forwarded" "ready
1
2
10
64
15[0]" "$(docker logs $N 2>&1)[$rc]"
ok "sealed: 3000 orphans reaped" "orphans made: 3000[0]" "$(r --pids-limit 100 --memory 128m $S kh orphans 3000 0)"
summary
