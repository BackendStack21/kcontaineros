# Runs inside the container under busybox sh. See probes.sh.
B=/bb/busybox
cd /tmp
t() { # script [extra sh args...]
  $B printf '%s' "$1" > /tmp/s; src=$1; shift
  ko=$(/bin/sh "$@" /tmp/s a1 'b 2' 2>/tmp/ke </dev/null); kr=$?
  bo=$($B sh "$@" /tmp/s a1 'b 2' 2>/tmp/be </dev/null); br=$?
  if [ "$ko" = "$bo" ] && [ $kr = $br ]; then echo "SAME [$src] -> $kr [$ko]"; else
  echo "DIFF [$src]"; echo "  kcos    status=$kr out=[$ko] err=[$($B cat /tmp/ke)]"; echo "  busybox status=$br out=[$bo] err=[$($B cat /tmp/be)]"; fi
}
echo "##### 1. line continuation inside a token"
t 'i\
f false
t\
hen
echo BODY RUNS
f\
i'
t 'w\
hile false
d\
o
echo LOOP BODY RUNS ONCE
d\
one'
t 'A=1; AB=2; echo $A\
B "$A\
B"'
t 'echo hi 2\
>/dev/null'
t 'a=\
~; echo "$a"'
t 'ev\
al echo hi; echo after $?'
t 'FO\
O=bar; echo "[$FOO]"'
t 'echo a &\
& echo b'
echo "##### 2. variables the shell itself should provide; set and export without operands"
t 'echo "a${IFS}b"'
t 'echo "[$LINENO]"'
t 'echo "[$OPTIND][$PS4]"'
t 'X=5; set | '$B' grep -c "^X="'
t 'X=5; export | '$B' grep -c "X="'
t 'PPID=7; echo $PPID'
echo "##### 3. accepted although POSIX sh rejects it"
t 'echo a ;; echo b'
t '; echo a'
t 'echo a & ; echo b; wait'
t 'echo x >#f; '$B' ls'
t 'echo x 2> 4>&1; '$B' cat 4'
$B rm -f '/tmp/#f' /tmp/4
echo "##### 4. error paths: the script goes on where busybox ends it"
t 'export 1a=3; echo after $?'
t 'export IFS=:; X=a:b; '$B' printf "<%s>" $X; echo " $?"'
t 'unset 1bad; echo after $?'
t 'true >&$NOFD; echo after $?'
t 'X=eval; $X echo hi; echo after $?'
t 'cd ""; echo $?'
t 'command exec >/tmp/o; echo visible'
t 'X=1 </nosuch; echo "[$X]"'
echo "##### 5. numbers"
t 'exit 256'
t 'exit 4294967296'
t 'exit 99999999999999999999'
t 'exit -1'
t 'exit 08'
t 'shift 99999999999999999999; echo no'
t 'shift -1; echo no'
t 'umask 99999; echo $?'
t 'umask 1777; echo $?'
t 'wait 0; echo $?'
t 'wait 4294967297; echo $?'
t 'wait 99999999999999999999; echo $?'
t 'echo a 99999999999999999999>f; echo $?'
t 'echo a 1024>f; echo $?'
t 'echo a >&1024; echo $?'
t 'echo a >&99999999999999999999; echo $?'
t 'echo ${99999999999999999999:-x} ${4294967297:-y} ${01}'
echo "##### 6. set -e"
t 'set -e; false | true; echo ok1; true | false; echo no'
t 'set -e; false || false; echo no'
t 'set -e; false && true; echo ok; false; echo no'
t 'set -e; false & wait $!; echo no'
t 'set -e; true && false & wait; echo after $?'
t 'set -e; cd /nosuch 2>/dev/null || echo handled; echo yes'
t 'set -e; X=1 false; echo no'
t 'set -e; : >/nosuch/x; echo no'
t 'set -e; nosuch 2>/dev/null; echo no'
t 'set -e; false && false || true; echo ok'
t 'set -e; true && false || false; echo no'
t 'false; echo ok' -e
t 'set +e; false; echo ok' -e
t 'set -e; set +e; false; echo ok'
t 'set -e; wait 99999; echo no'
t 'set -e; shift 9; echo no'
echo "##### 7. descriptors"
t $B' ls /proc/self/fd | '$B' tr "\n" " "; echo'
t 'command '$B' ls /proc/self/fd >/tmp/x 2>/tmp/y; '$B' tr "\n" " " </tmp/x; echo'
t 'true | '$B' ls /proc/self/fd | '$B' tr "\n" " "; echo'
t 'true | true | '$B' ls /proc/self/fd | '$B' tr "\n" " "; echo'
t 'exec 3>/tmp/x 7<&0; : 5>/tmp/y; cd / 4>/tmp/y; '$B' ls /proc/self/fd | '$B' tr "\n" " "; echo'
t ': >&-; echo still here'
t 'cd / >&- 2>&-; echo still here; echo too >&2'
t 'echo a >&- ; echo $?'
t 'echo a 5>&5; echo $?'
t ': 10>/tmp/x 11>&10 12>&11; echo $?'
t 'exec >&-; echo a; echo $? >&2'
echo "##### 8. script files without #!"
$B printf 'echo ran "$0" "$1" "$#"\n' >/tmp/noshebang; $B chmod +x /tmp/noshebang
$B printf '\000echo ran\n' >/tmp/nul; $B chmod +x /tmp/nul
: >/tmp/empty; $B chmod +x /tmp/empty
$B printf 'echo dash-c ran\n' >/tmp/-c; $B chmod +x /tmp/-c
t '/tmp/noshebang x y; echo $?'
t '/tmp/nul; echo $?'
t '/tmp/empty; echo $?'
t 'PATH=/tmp:$PATH; -c; echo $?'
t 'PATH=/tmp:$PATH; noshebang "a b"; echo $?'
t 'cd /tmp; PATH=; noshebang q; echo $?'
echo "##### 9. stdin: stops at the first syntax error"
printf 'echo one\nif true; then echo two; fi\necho three\n' | /bin/sh; echo "kcos status=$?"
printf 'echo one\necho "a\nb" &&\n\n# c\necho c\\\nd\n' | /bin/sh; echo "kcos status=$?"
echo "##### 10. echo, the applet"
t 'echo -n a; echo -e "b\tc"; echo "x\ty"; echo -- q; echo -E r; echo -ne s; echo - t; echo'
t 'echo -neE "a\tb"; echo; echo -nEe "a\tb"; echo'
t 'echo -e "a\0101b\x41\c" z; echo'
echo "##### 11. environment handed to the shell (kcos, then busybox)"
big=$($B awk 'BEGIN { for (i = 0; i < 100000; i++) printf "v" }')
for S in /bin/sh "$B sh"; do
  $B env -i PATH=/usr/local/bin:/usr/bin:/bin:/sbin IFS=: PWD=/lie OLDPWD=/bb 'B C=blank' 1X=digit a-b=dash D=x=y "BIG=$big" \
    $S -c 'X=a:b; '$B' printf "<%s>" $X "$PWD" "$D"; echo; cd -; '$B' env | '$B' grep -c "^B C=\|^1X=\|^a-b="; unset D; echo "[$D]"; echo $BIG | '$B' wc -c; BIG=$BIG$BIG; '$B' true; echo "true after doubling BIG: $?"' 2>&1
done
