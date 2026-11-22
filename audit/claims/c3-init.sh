# /sbin/init: signals, exit status, zombies, stopping, the terminal, running nested.
echo "== init"
BIOPT=()
C=kcos-audit-claims-c
dstart() { docker rm -f $C >/dev/null 2>&1; timeout 60 docker run -d "${P[@]}" --name $C "$@" >/dev/null; }
dend() { docker rm -f $C >/dev/null 2>&1; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

claim N001 "R/I: init is PID 1 and runs the command as its child"
t "ps in a fresh container: PID 1 is /sbin/init, the command another process" 0 "1 S /sbin/init ps|R ps|" -- \
  sh -c "timeout 60 docker run --rm --platform linux/arm64 $IMG ps | awk 'NR>1{if(\$1==1) printf \"%s %s %s %s|\", \$1,\$2,\$3,\$4; else printf \"%s %s|\", \$2,\$3}'"
claim N002 "R/I: exits with the command's status; 128 + signal when the command is killed"
for rc in 0 1 42 255; do t "exit $rc" $rc "" -- R "$IMG" sh -c "exit $rc"; done
t "killed by SIGKILL: 137" 137 "" -- R "$IMG" sh -c 'kill -9 $$'
t "killed by SIGTERM: 143" 143 "" -- R "$IMG" sh -c 'kill -TERM $$'
t "killed by SIGSEGV: 139" 139 "" -- R "$IMG" sh -c 'kill -11 $$'
claim N003 "R/I: forwards every signal to the command (features table: every catchable signal, sent to the command's PID)"
TRAPS='for n in $(/bb/busybox seq 1 31); do case $n in 9|19) ;; *) trap "echo got-$n" $n;; esac; done; echo ready; /bb/busybox sleep 1000 & while :; do wait; done'
dstart "$A" /bb/busybox sh -c "$TRAPS"; sleep 1.5
for n in $(seq 1 31); do case $n in 9|19) ;; *) docker kill -s $n $C >/dev/null 2>&1; sleep 0.15;; esac; done; sleep 0.5
want="ready "; for n in $(seq 1 31); do case $n in 9|19) ;; *) want="${want}got-$n ";; esac; done
v "docker kill -s N for N = 1..31 without KILL and STOP, the command traps each" "$want" "$(docker logs $C 2>&1 | tr '\n' ' ')"
dend
dstart "$A" /bb/busybox sleep 300; sleep 1; docker exec $C /bb/sc 129 1 34 >/dev/null; sleep 0.5
v "a real-time signal (34) sent to PID 1 ends a command without a handler for it: exit 128+34" 162 "$(docker inspect -f '{{.State.ExitCode}}' $C)"; dend
dstart "$A" /bb/busybox sleep 300; sleep 1; docker exec $C /bb/sc 129 1 64 >/dev/null; sleep 0.5
v "  and signal 64: exit 128+64" 192 "$(docker inspect -f '{{.State.ExitCode}}' $C)"; dend

claim N004 "R/I: docker stop reaches the command at once; exit 143 (Compared with Alpine: 0.11 s, exit 143 on sleep 300)"
times=""; codes=""
for i in 1 2 3 4 5; do dstart "$IMG" sleep 300; sleep 1; t0=$(now_ms); docker stop $C >/dev/null; t1=$(now_ms); times="$times $((t1 - t0))"; codes="$codes$(docker inspect -f '{{.State.ExitCode}}' $C) "; dend; done
echo "        docker stop on sleep 300, 5 runs, ms:$times"
max=$(printf '%s\n' $times | sort -n | tail -1)
v "five stops: every exit status 143" "143 143 143 143 143 " "$codes"
v "five stops: the slowest under 1000 ms (measured:$times)" yes "$([ "$max" -lt 1000 ] && echo yes || echo no)"
echo "$times" > "$OUT/stop-kcos.txt"
claim N005 "R: graceful stop of shell-form commands: the shell replaces itself with the last command, so the signal reaches your program"
dstart "$A" sh -c 'cd /tmp; /bb/busybox sleep 300'; sleep 1
v "sh -c 'cd /tmp; /bb/busybox sleep 300': processes under init" "/sbin/init sh -c cd /tmp; /bb/busybox sleep 300|/bb/busybox sleep 300|" "$(docker exec $C /bb/busybox sh -c '/bin/ps' | awk 'NR>1 && $NF!="/bin/ps" && $3!="/bb/busybox" || ($3=="/bb/busybox" && $4=="sleep"){ $1=""; $2=""; sub(/^ +/,""); printf "%s|", $0}')"
t0=$(now_ms); docker stop $C >/dev/null; t1=$(now_ms)
v "  docker stop: exit 143 within a second ($((t1 - t0)) ms)" "143 yes" "$(docker inspect -f '{{.State.ExitCode}}' $C) $([ $((t1 - t0)) -lt 1000 ] && echo yes || echo no)"; dend
claim N006 "R/I: reaps zombies: orphans are adopted and reaped"
ORPHANS='/bb/busybox sh -c "/bb/busybox sleep 0.5 & /bb/busybox sleep 0.6 & /bb/busybox sleep 0.7 &"; /bb/busybox sleep 30'
zombies() { docker exec $C /bb/busybox ps -o stat,comm | grep -c '^Z'; }
dstart "$A" sh -c "$ORPHANS"; sleep 2.5
v "three orphans that exit while the command sleeps: zombies left" 0 "$(zombies)"; dend
dstart --entrypoint /bin/sh "$A" -c "$ORPHANS"; sleep 2.5
v "control: without init (the command itself is PID 1) they stay" 3 "$(zombies)"; dend
claim N007 "R: init error reporting: a missing command 127, a file that is not a program 126; -- ends init's arguments; with no command it runs /bin/sh"
t "missing command" 127 "kcontaineros: nope: no such file or directory" -- R "$IMG" nope
t "not executable" 126 "kcontaineros: /etc/passwd: permission denied" -- R "$IMG" /etc/passwd
t "ENTRYPOINT [\"/sbin/init\", \"--\", ...]" 0 "kept" -- R --entrypoint /sbin/init "$IMG" -- echo kept
t "no command: /bin/sh reads its script from stdin (empty here)" 0 "" -- R "$IMG"
claim N008 "R: if you set your own ENTRYPOINT, or pass --entrypoint, init and everything it enforces are gone"
t "--entrypoint /bb/busybox: no filter, no no_new_privs, capabilities as Docker gives them, writes to a program directory" 0 $'CapEff:\t00000000a80425fb\nNoNewPrivs:\t0\nSeccomp:\t2\nwrote' -- \
  R --entrypoint /bb/busybox "$A" sh -c '/bb/busybox grep -E "^(NoNewPrivs|Seccomp|CapEff):" /proc/self/status; echo x > /bb/x && echo wrote'
claim N009 "R/I: never allocates; as PID 1 it never polls: it sleeps in rt_sigtimedwait; no signal handlers and no threads"
dstart "$A" /bb/busybox sleep 300; sleep 1
a=$(docker exec $C /bb/busybox sh -c '/bb/busybox awk "/ctxt_switches/{s+=\$2} END{print s}" /proc/1/status; /bb/busybox cut -d" " -f14,15 /proc/1/stat' | tr '\n' ' '); sleep 5
b=$(docker exec $C /bb/busybox sh -c '/bb/busybox awk "/ctxt_switches/{s+=\$2} END{print s}" /proc/1/status; /bb/busybox cut -d" " -f14,15 /proc/1/stat' | tr '\n' ' ')
v "PID 1's context switches and CPU ticks do not change over 5 idle seconds" "$a" "$b"
# (SigBlk reads 0 while PID 1 sleeps in rt_sigtimedwait: the kernel unblocks the awaited set for the duration.)
v "PID 1: one thread, no signal caught" $'Threads:\t1|SigCgt:\t0000000000000000|' \
  "$(docker exec $C /bb/busybox grep -E '^(Threads|SigCgt):' /proc/1/status | tr '\n' '|')"
v "PID 1's memory map (read with docker exec --privileged): no heap; the only anonymous memory besides the stack and the kernel's pages is the binary's own writable page" "1 mapping(s), 4 kB" \
  "$(docker exec --privileged -u 0 $C /bb/busybox sh -c '/bb/busybox cat /proc/1/maps' | grep -v -E 'kcontaineros|\[stack\]|\[vdso\]|\[vvar\]|\[vvar_vclock\]' | python3 -c 'import sys; L=[l.split()[0].split("-") for l in sys.stdin]; print("%d mapping(s), %d kB" % (len(L), sum(int(b,16)-int(a,16) for a,b in L)//1024))')"
docker exec --privileged -u 0 $C /bb/busybox cat /proc/1/maps > "$OUT/pid1-maps.txt" 2>&1
dend
claim N010 "R: works under docker run --init too"
t "docker run --init" 0 "with-docker-init" -- R --init "$IMG" echo with-docker-init

claim N011 "I (terminal session): a session as the default user, from 'docker run -it --rm kcontaineros' to 'exit 7'"
want=$(python3 $HERE/pagesession.py docs/index.html 1 | sed '1d' | sed '/^\$ echo \$?$/,$d')
got=$(python3 test/term.py 'ps\n' 'cp /bin/ls /tmp/ls\n' '/tmp/ls\n' 'touch /usr/local/bin/x\n' 'mkdir /app\n' 'echo hi > /tmp/note; cat /tmp/note\n' 'exit 7\n' -- docker run -it --rm "${P[@]}" "$IMG")
v "the transcript, character for character, and the exit status the page shows after it" "$want
[exit 7]" "$got"
claim N012 "R: -it interactive terminal: prompt, Ctrl-C, Ctrl-D; Ctrl-Z has no effect on the command init started"
got=$(python3 test/term.py 'sleep 100\n' '\x03' 'echo "rc=$?"\n' '\x1a' 'echo after-z\n' '\x04' -- docker run -it --rm "${P[@]}" "$IMG" | tr -d '\r')
v "sleep 100, Ctrl-C, echo rc, Ctrl-Z, echo, Ctrl-D: prompt lines and output lines" '/ $ sleep 100|/ $ echo "rc=$?"|rc=130|after-z|[exit 0]|' \
  "$(printf '%s\n' "$got" | grep -x -E '/ \$ sleep 100|.*echo "rc=\$\?"|rc=[0-9]+|after-z|\[exit .*\]' | sed 's/^\^C//' | tr '\n' '|')"
got=$(python3 test/term.py '\x1a' -- docker run -it --rm "${P[@]}" "$A" /bb/busybox sleep 3 | tr -d '\r' | tail -1)
v "Ctrl-Z typed at a foreground command that leaves it at its default: the command still ends by itself" "^Z[exit 0]" "$got"
claim N013 "R: running nested, not as PID 1: stops what the command left behind (SIGTERM, then SIGKILL after 2 s), in whatever session or process group; exit status passes through"
t "leftovers that take SIGTERM are gone at once" 0 $'inner\nrc=5\nleft=0' -- \
  R --entrypoint /bb/busybox "$A" sh -c '/sbin/init /bb/busybox sh -c "/bb/busybox sleep 50 & /bb/busybox setsid /bb/busybox sleep 51 & echo inner; exit 5"; echo "rc=$?"; /bb/busybox sleep 0.3; echo "left=$(/bb/busybox pgrep -f "^/bb/busybox sleep 5[01]\$" | /bb/busybox wc -l)"'
t "leftovers that ignore SIGTERM are killed, after about 2 s" 0 $'rc=0\nleft=0\nwaited 2 s' -- \
  R --entrypoint /bb/busybox "$A" sh -c 'up() { /bb/busybox awk "{print int(\$1 * 1000)}" /proc/uptime; }; s=$(up); /sbin/init /bb/busybox sh -c "trap \"\" TERM; /bb/busybox sleep 60 & /bb/busybox sleep 0.2"; echo "rc=$?"; e=$(up); echo "left=$(/bb/busybox pgrep -f "^/bb/busybox sleep 60\$" | /bb/busybox wc -l)"; ms=$((e - s)); [ $ms -ge 2000 ] && [ $ms -lt 3500 ] && echo "waited 2 s" || echo "waited $ms ms"'
tc "the same command without init leaves its children running" 0 $'inner\nrc=5\nleft=2' -- \
  R --entrypoint /bb/busybox "$A" sh -c '/bb/busybox sh -c "/bb/busybox sleep 50 & /bb/busybox setsid /bb/busybox sleep 51 & echo inner; exit 5"; echo "rc=$?"; /bb/busybox sleep 0.3; echo "left=$(/bb/busybox pgrep -f "^/bb/busybox sleep 5[01]\$" | /bb/busybox wc -l)"'
t "kcontaineros init COMMAND is the same thing" 3 "x" -- R --entrypoint /bin/kcontaineros "$IMG" init sh -c 'echo x; exit 3'
claim N014 "R: 'docker exec' works; that shell starts outside init: it cannot gain privileges and is under the filter, but not the run-or-write rule and keeps Docker's capabilities; other programs started that way get only what Docker gives them"
dstart "$A" /bb/busybox sleep 300; sleep 1
v "docker exec CONTAINER sh -c ...: no_new_privs and filter on, capabilities kept" $'CapEff:\t00000000a80425fb|NoNewPrivs:\t1|Seccomp:\t2|' \
  "$(docker exec $C sh -c 'cat /proc/self/status' | grep -E '^(CapEff|NoNewPrivs|Seccomp):' | tr '\n' '|')"
v "  it writes to a program directory and runs a program from /tmp (not under Landlock)" "ret=" "$(docker exec $C sh -c 'cp /bb/sc /bb/copy; cp /bb/sc /tmp/sc; /tmp/sc 172' 2>&1 | sed 's/[0-9]*$//')"
v "  a utility started that way refuses the filtered calls for its children too (sh -> sc memfd_create)" "errno=1" "$(docker exec $C sh -c '/bb/sc 279 s:x 0' 2>&1)"
v "docker exec of another program (busybox): no no_new_privs, no filter of ours" $'NoNewPrivs:\t0|Seccomp:\t2|' \
  "$(docker exec $C /bb/busybox grep -E '^(NoNewPrivs|Seccomp):' /proc/self/status | tr '\n' '|')"
v "  and memfd_create is not refused there" "ret=3" "$(docker exec $C /bb/sc 279 s:x 0)"
dend
