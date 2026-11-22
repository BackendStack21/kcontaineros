#!/bin/bash
# Runtime probes for the memory-safety track. From the repo root:
#
#   sh audit/memory/build.sh        # once: the two helper images
#   bash audit/memory/run.sh        # this file: about 3 minutes
#
# Every probe prints one line:  verdict | name | what was seen
# verdict is "held" (as documented / as a careful program should), "FINDING"
# (see REPORT.md) or "note". Nothing is written outside the containers, every
# container is --rm, time-limited and named kcos-audit-memory-*.
#
# Images: kcontaineros (release), kcos-audit-memory-img (kcos-audit plus
# /bb/hexec, root, KCOS_EXEC=/bb), kcos-audit-memory-sealed.

I=kcos-audit-memory-img
SEALED=kcos-audit-memory-sealed
H=/bb/hexec
COUNT="$(cd "$(dirname "$0")" && pwd)/.run-count.$$"   # containers started (D runs in subshells)
: > "$COUNT"; trap 'rm -f "$COUNT"' EXIT
D() { echo >> "$COUNT"; timeout 300 docker run --rm --platform linux/arm64 --name "kcos-audit-memory-run-$$-$RANDOM" "$@"; }
# without init, busybox on PATH (the control / the driver)
C() { D -e PATH=/bb:/bin --entrypoint /bb/busybox "$@"; }
line() { printf '%-7s | %s | %s\n' "$1" "$2" "$3"; }
oneline() { tr '\n' ' ' | cut -c1-"${1:-160}"; }
sorted() { sort | oneline; }   # stdout and stderr of a probe may arrive in either order
held=0; findings=0; notes=0
verdict() { # verdict name seen
  case "$1" in held) held=$((held+1));; FINDING) findings=$((findings+1));; *) notes=$((notes+1));; esac
  line "$1" "$2" "$3"
}
expect() { # name expected actual
  if [ "$2" = "$3" ]; then verdict held "$1" "$3"; else verdict FINDING "$1" "expected [$2] got [$3]"; fi
}

echo "== f. the process image at run time"
maps=$(D kcontaineros cat /proc/self/maps)
echo "$maps" | sed 's/^/    /'
expect "no mapping is writable and executable" "0" "$(echo "$maps" | awk '$2 ~ /w/ && $2 ~ /x/' | wc -l | tr -d ' ')"
expect "stack is rw-, not executable" "rw-p" "$(echo "$maps" | awk '/\[stack\]/{print $2}')"
expect "relocated tables are read-only after start (file offset 0x14000)" "r--p" "$(echo "$maps" | awk '$3=="00014000"{print $2}')"
expect "heap chunk (anonymous, 256 KiB) is rw-" "rw-p" "$(echo "$maps" | awk 'NR==1{print $2}')"
bases=$(for k in 1 2 3 4 5; do D kcontaineros cat /proc/self/maps | awk '/r-xp.*kcontaineros/{print $1}'; done | sort -u | wc -l | tr -d ' ')
expect "text base differs in each of 5 starts (PIE + ASLR)" "5" "$bases"
initmaps=$(C --cap-add SYS_PTRACE $I sh -c '/bin/kcontaineros init /bb/busybox sleep 2 & sleep 1; cat /proc/$!/maps')
expect "init (not PID 1, read with CAP_SYS_PTRACE in a control run): no rwx, no anonymous heap chunk" "0 0" \
  "$(echo "$initmaps" | awk '$2 ~ /w/ && $2 ~ /x/' | wc -l | tr -d ' ') $(echo "$initmaps" | awk '$6=="" && $2=="rw-p"{split($1,a,"-"); if (("0x" a[2])-("0x" a[1]) > 65536) n++} END{print n+0}')"

echo "== b. entry: argv and envp the kernel hands over"
expect "execve with argc=0 (kernel makes argv[0] \"\"), release sh" "[exit 127] kcontaineros: : applet not found " \
  "$(D --entrypoint $H $I report $H argc0 /bin/sh 2>&1 </dev/null | sorted)"
expect "execve with argc=0, release /sbin/init" "[exit 127] kcontaineros: : applet not found " \
  "$(D --entrypoint $H $I report $H argc0 /sbin/init 2>&1 </dev/null | sorted)"
expect "execve with argc=0, sealed /sbin/init: default command, which the sealed image lacks" "[exit 127] kcontaineros: /bin/sh: no such file or directory " \
  "$(D --entrypoint $H $SEALED report $H argc0 /sbin/init 2>&1 </dev/null | sorted)"
expect "sealed init under any argv[0] runs the command" "[exit 42] " \
  "$(D --entrypoint $H $SEALED report $H argv0 anything /sbin/init $H tiny 2>&1 | oneline)"
for n in "" "/" "init/" "/bin/" "-sh"; do
  # the name shown is what follows the last slash
  expect "argv[0]=[$n] is not a personality" "[exit 127] kcontaineros: ${n##*/}: applet not found " \
    "$(D --entrypoint $H $I report $H argv0 "$n" /bin/kcontaineros --version 2>&1 </dev/null | sorted)"
done
expect "envp with entries lacking '=', empty ones and duplicates: sh sees the first PATH and the first KCOS_EXEC" "[/nonexistent][][][] [exit 0] " \
  "$(D --entrypoint $H $I report $H noeq /bin/sh -c 'echo "[$PATH][$NOEQ][$A][$KCOS_EXEC]"' 2>&1 | sorted)"
expect "same envp through init: the first KCOS_EXEC (empty) is the one that counts, /bb stays non-executable" "[exit 0] rc=126 sh: /bb/busybox: permission denied " \
  "$(D --entrypoint $H $I report $H noeq /sbin/init /bin/sh -c '/bb/busybox true; echo rc=$?' 2>&1 | sorted)"
expect "100000 environment entries: sh" "x [exit 0] " "$(D --entrypoint $H $I report $H bigenv 100000 1 /bin/sh -c 'echo $V99999' 2>&1 | oneline)"
expect "100000 environment entries: init" "x [exit 0] " "$(D --entrypoint $H $I report $H bigenv 100000 1 /sbin/init /bin/sh -c 'echo $V99999' 2>&1 | oneline)"
expect "15 environment entries of 131000 bytes: init" "[exit 0] " "$(D --entrypoint $H $I report $H bigenv 15 131000 /sbin/init /bin/true 2>&1 | oneline)"
expect "100000 arguments to echo" "100000" "$(C $I sh -c 'seq 1 100000 | xargs -s 2000000 /bin/echo | wc -w')"
out=$(C $I sh -c 'bad=0; for a in cat chmod chown cp echo env false kill ln ls mkdir mv ps pwd rm sleep touch true uname sh; do r=$('$H' report '$H' bigarg 131071 /bin/$a 2>&1 </dev/null | tail -c 12); case "$r" in *"[exit 0]"*|*"[exit 1]"*|*"[exit 127]"*) ;; *) bad=$((bad+1)); echo "$a: $r";; esac; done; echo "bad=$bad"')
expect "one 131071-byte argument (the kernel's maximum) to each of 20 personalities: exit 0, 1 or 127" "bad=0" "$out"

echo "== a. kernel ABI spot checks"
expect "statx layout: ls -l shows the mode, uid, gid and size busybox stat reports" "same" \
  "$(C $I sh -c 'cd /tmp; dd if=/dev/zero of=f bs=1 count=12345 2>/dev/null; chmod 4751 f; chown 123:456 f; a=$(/bin/ls -l f); b=$(stat -c "%A %u %g %s %n" f); [ "$a" = "$b" ] && echo same || echo "kcos[$a] busybox[$b]"')"
expect "statx layout: device and inode identify a file (cp onto a hard link of itself is refused)" "cp: a: source and destination are the same file rc=1" \
  "$(C $I sh -c 'cd /tmp; echo x >a; ln a b; /bin/cp a b 2>&1; echo rc=$?' | oneline | sed 's/ $//')"
expect "linux_dirent64 layout: ls lists names of 1, 255 bytes and all types as busybox does" "same" \
  "$(C $I sh -c 'mkdir /tmp/d; cd /tmp/d; touch a $(printf "%0255d" 7); mkdir dir; ln -s a l; mkfifo p; a=$(/bin/ls -a | sort); b=$(ls -a | grep -v "^\.\.\?$" | sort); [ "$a" = "$b" ] && echo same || echo differ')"
expect "utsname layout: uname -a fields equal busybox's (sysname nodename release version machine)" "same" \
  "$(C $I sh -c 'a=$(/bin/uname -a); b="$(uname -s) $(uname -n) $(uname -r) $(uname -v) $(uname -m)"; [ "$a" = "$b" ] && echo same || echo "[$a] [$b]"')"
expect "hostile process names (\") R 1 (\", escape codes) do not confuse ps" "[a) R 1 (b] [?[31mX??]" \
  "$(D $I $H comm 'a) R 1 (b' /bin/ps | awk '$3 ~ /^\[/{sub(/^ *[0-9]+ [A-Z] /,""); print}' | oneline | sed 's/ $//') $(D $I $H comm "$(printf '\033[31mX\n\001')" /bin/ps | awk '$3 ~ /^\[/{sub(/^ *[0-9]+ [A-Z] /,""); print}' | oneline | sed 's/ $//')"

echo "== c. out of memory"
expect "RLIMIT_AS 4 MiB, a variable doubling past it: message and exit 101, no fault" "kcontaineros: out of memory [exit 101] " \
  "$(C $I sh -c $H' report '$H' rlim as 4194304 /bin/sh -c "A=xxxxxxxxxxxxxxxx; A=\$A\$A\$A\$A; A=\$A\$A\$A\$A; A=\$A\$A\$A\$A; A=\$A\$A\$A\$A; A=\$A\$A\$A\$A; A=\$A\$A\$A\$A; A=\$A\$A\$A\$A; A=\$A\$A\$A\$A; A=\$A\$A\$A\$A; A=\$A\$A\$A\$A; echo survived" 2>&1' | oneline)"
expect "RLIMIT_AS 511 KiB (one page short of the first heap chunk): message and exit 101" "kcontaineros: out of memory [exit 101] " \
  "$(C $I sh -c $H' report '$H' rlim as $((511*1024)) /bin/echo hi 2>&1' | oneline)"
expect "RLIMIT_AS 512 KiB: echo works" "hi [exit 0] " "$(C $I sh -c $H' report '$H' rlim as $((512*1024)) /bin/echo hi 2>&1' | oneline)"
verdict note "RLIMIT_AS 400 KiB: the kernel kills the exec itself (its one-piece mapping of the 280 KiB image span does not fit); a 60 KiB static C program still starts" \
  "kcos: $(C $I sh -c $H' report '$H' rlim as $((400*1024)) /bin/echo hi 2>&1' | oneline) control: $(C $I sh -c $H' report '$H' rlim as $((400*1024)) '$H' tiny 2>&1' | oneline)"
D --memory 16m --memory-swap 16m $I /bin/sh -c 'A=xxxxxxxxxxxxxxxx; A=$A$A$A$A; A=$A$A$A$A; A=$A$A$A$A; A=$A$A$A$A; A=$A$A$A$A; A=$A$A$A$A; A=$A$A$A$A; A=$A$A$A$A; A=$A$A$A$A; A=$A$A$A$A; A=$A$A$A$A; A=$A$A$A$A; A=$A$A$A$A; echo survived' >/dev/null 2>&1
expect "cgroup limit 16 MiB, same script under init: the kernel kills the shell, init survives and reports 137" "137" "$?"

echo "== e. stack"
for k in 4 12 16 24; do
  verdict note "RLIMIT_STACK ${k} KiB (no init): echo / init echo / control" \
    "$(C $I sh -c 'a=$('$H' report '$H' rlim stack $(('$k'*1024)) /bin/echo hi 2>&1 | tr "\n" " "); c=$('$H' report '$H' rlim stack $(('$k'*1024)) /bin/kcontaineros init /bin/echo hi 2>&1 | tr "\n" " "); b=$('$H' report '$H' rlim stack $(('$k'*1024)) '$H' tiny 2>&1 | tr "\n" " "); echo "$a/ $c/ $b"')"
done
D --ulimit stack=8192 $I /bin/echo under-init >/dev/null 2>&1
verdict note "docker run --ulimit stack=8192 (bytes): init dies of SIGSEGV before it starts the command (fails closed)" "exit status $?"
rmdeep() { # depth stackKiB nofile
  C --tmpfs /tmp:size=64m $I sh -c '
mkdir -p /tmp/t && cd /tmp/t && '$H' deep '$1' && cd /tmp
if [ '$2' != 0 ]; then '$H' report '$H' rlim stack $(('$2'*1024)) /bin/rm -r /tmp/t >/tmp/out 2>&1
elif [ '$3' != 0 ]; then '$H' report '$H' rlim nofile '$3' /bin/rm -r /tmp/t >/tmp/out 2>&1
else '$H' report /bin/rm -r /tmp/t >/tmp/out 2>&1; fi
echo "$(grep -o -e "directory tree too deep" -e "too many open files" /tmp/out | head -1) $(tail -1 /tmp/out) tree left: $([ -e /tmp/t ] && echo yes || echo no)"'
}
expect "rm -r, 4096 directories deep (the documented limit), default 8 MiB stack" " [exit 0] tree left: no" "$(rmdeep 4095 0 0)"
expect "rm -r, 4097 deep: refused, loudly" "directory tree too deep [exit 1] tree left: yes" "$(rmdeep 4096 0 0)"
expect "rm -r, 2001 deep with 1024 descriptors: refused, loudly" "too many open files [exit 1] tree left: yes" "$(rmdeep 2000 0 1024)"
expect "rm -r, 4001 deep with a 1 MiB stack" " [exit 0] tree left: no" "$(rmdeep 4000 1024 0)"
r=$(rmdeep 4000 512 0)
if [ "$r" = " [signal 11] tree left: yes" ]; then verdict FINDING "M-2 rm -r, 4001 deep with a 512 KiB stack: SIGSEGV instead of a refusal" "$r"; else verdict held "rm -r, 4001 deep with a 512 KiB stack" "$r"; fi
D kcontaineros /bin/sh -c 'PATH=/nonexistent; sh -c "$0" "$0"' 'sh -c "$0" "$0"' >/dev/null 2>&1; rc=$?
if [ $rc = 139 ]; then verdict FINDING "M-1 sh re-entering itself when sh is not on PATH recurses in-process until the stack is gone" "exit status 139 (SIGSEGV)"; else verdict held "sh re-entering itself when sh is not on PATH" "exit status $rc"; fi
expect "\${A:-...} nested 32 deep expands; 33 deep is a syntax error" "x rc=0 / sh: syntax error: \${NAME:-default} is nested too deeply rc=2" \
  "$(n32=$(python3 -c "print('\${A:-'*32+'x'+'}'*32)"); n33=$(python3 -c "print('\${A:-'*33+'x'+'}'*33)"); a=$(D kcontaineros /bin/sh -c "echo $n32" 2>&1; echo " rc=$?"); b=$(D kcontaineros /bin/sh -c "echo $n33" 2>&1; echo " rc=$?"); echo "$a / $b" | tr -d '\n' | sed 's/ rc/ rc/g')"

echo "== d. panics, lengths, buffers"
for n in 480 491 492 511 512 513 1024 100000; do
  A=$(python3 -c "print('A'*$n)")
  out=$(D -t kcontaineros ls "$A" 2>&1)
  expect "error message with a $n-byte name on a terminal (512-byte buffer in eprint): every byte arrives" "$n" "$(printf '%s' "$out" | tr -cd A | wc -c | tr -d ' ')"
done
expect "tools with descriptors 0, 1, 2 closed in every combination: 66 runs, none dies of a signal or exits 101" "bad=0" \
  "$(C --tmpfs /tmp:size=16m $I sh -c 'cd /tmp; bad=0
for fds in 0 1 2 01 12 012; do
 for c in "/bin/echo hi" "/bin/ls /etc" "/bin/cat /etc/hostname" "/bin/cp /etc/hostname /tmp/cp.$fds" "/bin/sh -c \"echo a | /bin/cat; echo b >&2; /bin/ls /nonexistent\"" "/bin/ps" "/bin/kcontaineros init /bin/echo from-init" "/bin/rm -r /tmp/nonexistent" "/bin/env" "/bin/pwd" "/bin/uname -a"; do
   out=$(eval "'$H' report '$H' closefd $fds $c" 2>&1 | tail -1)
   case "$out" in "[exit 0]"|"[exit 1]") ;; *) bad=$((bad+1)); echo "closed=$fds $c: $out";; esac
 done
 cmp -s /tmp/cp.$fds /etc/hostname || { bad=$((bad+1)); echo "copy with $fds closed differs"; }
done; echo "bad=$bad"')"

echo "== findings of the functional kind"
r=$(C --tmpfs /tmp:size=64m $I sh -c 'cd /tmp; '$H' deep 1364 dd; P=$(awk "BEGIN{for(i=0;i<1364;i++) printf \"dd/\"}"); cd /tmp; /bin/sh -c "cd \"\$1\"; echo \"rc=\$? PWD=\$PWD\"; echo x >\"\$PWD/marker\"; /bin/ls" sh "$P" 2>&1 | tr "\n" " "; echo "| /tmp/marker exists: $([ -e /tmp/marker ] && echo yes || echo no)"')
if echo "$r" | grep -q "rc=0 PWD=/tmp .*marker exists: yes"; then verdict FINDING "M-3 cd into a directory whose path is 4096 bytes or longer succeeds but leaves \$PWD naming the old directory" "$r"; else verdict held "cd into a 4096-byte path keeps \$PWD right" "$r"; fi
t=$(C --memory 1g --tmpfs /tmp:size=64m $I sh -c '
now() { read u _ </proc/uptime; echo ${u%.*}${u#*.}; }
for n in 4000 8000 16000; do awk -v n=$n "BEGIN{for(i=0;i<n;i++) printf \"V%d=%0100d \", i, 0; print \":\"}" > /tmp/s; s=$(now); /bin/sh /tmp/s; e=$(now); printf "%s assignments: %s ms; " $n $(( (e-s)*10 )); done')
verdict FINDING "M-4 one command with N assignments takes time quadratic in N" "$t"
t=$(C --memory 1g --tmpfs /tmp:size=64m $I sh -c '
now() { read u _ </proc/uptime; echo ${u%.*}${u#*.}; }
for n in 4000 8000 16000; do awk -v n=$n "BEGIN{print \"echo \${A:-\"; for(i=0;i<n;i++) printf \"%080d\n\", 0; print \"} >/dev/null\"}" > /tmp/s; s=$(now); /bin/sh </tmp/s; e=$(now); printf "%s lines: %s ms; " $n $(( (e-s)*10 )); done')
verdict FINDING "M-4 a script on stdin with an open \${ re-checks everything read so far on every line" "$t"

echo
echo "probes: $((held+findings+notes)) lines ($held held, $findings FINDING, $notes note); containers started: $(wc -l < "$COUNT" | tr -d " ")"
