# Inside the container, under init, as root without capabilities.
# Safety of the destructive tools on trees the differential cannot hold.
B=/bb/busybox; W=/work
say() { echo; echo "== $*"; }
first() { $B head -c 300 "$1" | $B tr '\n' '|' | $B tr -c ' -~' '?'; }

say "rm refuses the root, . and .. however they are spelled (canary and / must be untouched)"
$B mkdir -p $W/c/d/sub; echo keep > $W/c/keep; echo keep > $W/c/d/keep; echo keep > $W/c/d/sub/keep; $B ln -s / $W/c/rootlink; $B ln -s . $W/c/dotlink
cd $W/c/d
before="$($B find $W/c | $B wc -l) $(/bin/ls / | $B wc -l) $(/bin/ls /tmp /etc /bb | $B wc -l)"
for op in / // /// /. /.. /./ /../ . .. ./ ../ .// ..// ./. ../.. sub/.. sub/../ sub/../.. sub/. /tmp/.. /tmp/../ /tmp/../.. /work/c/d/. \
          /proc/self/root /proc/self/root/ /proc/self/root/. /proc/self/cwd /proc/self/cwd/ /proc/1/root/ \
          ../rootlink/ ../rootlink/. ../rootlink/.. ../dotlink/ ../dotlink/. ; do
  for fl in -rf -r -f ""; do
    /bin/rm $fl "$op" >$W/o 2>$W/e; rc=$?
    $B printf '%-28s rc=%s %s\n' "rm $fl $op" $rc "$(first $W/e)"
  done
done
after="$($B find $W/c | $B wc -l) $(/bin/ls / | $B wc -l) $(/bin/ls /tmp /etc /bb | $B wc -l)"
# the two links themselves may be removed by the plain forms: count them out
echo "entries before: $before   after: $after   links left: $([ -L $W/c/rootlink ] && echo rootlink) $([ -L $W/c/dotlink ] && echo dotlink)"
cd $W; /bin/rm -rf $W/c; echo "cleanup rc=$?"

say "rm -r: what it cannot remove it reports once; a directory it may not delete is still emptied"
$B mkdir -p $W/p/locked/in $W/p/open/in; for i in 1 2 3; do echo x > $W/p/locked/f$i; echo x > $W/p/locked/in/g$i; echo x > $W/p/open/f$i; echo x > $W/p/open/in/g$i; done
$B chmod 555 $W/p/locked/in $W/p/locked
/bin/rm -rf $W/p >$W/o 2>$W/e; echo "rm -rf p (p/locked and p/locked/in are mode 555): rc=$?"; $B cat $W/e; echo "left:"; $B find $W/p | LC_ALL=C $B sort
$B chmod -R u+w $W/p; $B rm -rf $W/p
$B mkdir -p $W/p/q/r; echo x > $W/p/q/f; echo x > $W/p/q/r/g; $B chmod 555 $W/p
/bin/rm -r $W/p/q >$W/o 2>$W/e; echo "rm -r p/q (p is mode 555): rc=$?"; $B cat $W/e; echo "left:"; $B find $W/p | LC_ALL=C $B sort
$B chmod -R u+w $W/p; $B rm -rf $W/p

say "deep trees: rm -r at and beyond the documented limit of 4096 levels (built and measured by /bb/h, not by path)"
E=/tmp/e   # messages go to the image filesystem: /work may be full
for n in 1000 4095 4096 4097 4098 6000 20000; do
  /bb/h mkdeep $W/deep$n $n x
  /bin/rm -r $W/deep$n >$W/o 2>$E; rc=$?
  echo "kcontaineros rm -r, $n levels: rc=$rc, levels left $(/bb/h depth $W/deep$n x), stderr $($B wc -l < $E) line(s), $($B wc -c < $E) bytes, ending: $($B tail -c 50 $E | $B tr '\n' '|')"
done
/bin/rm -rf $W/deep6000 2>$E; echo "a second rm -rf of the 6000-level tree: rc=$?, levels left $(/bb/h depth $W/deep6000 x)"
/bb/h mkdeep $W/bdeep 3000 x; $B rm -r $W/bdeep >$W/o 2>$E; echo "busybox rm -r, 3000 levels (path 6 kB): rc=$?, levels left $(/bb/h depth $W/bdeep x): $(first $E | $B cut -c1-60)"
/bin/rm -rf $W/bdeep; echo "kcontaineros cleans that up: rc=$?, levels left $(/bb/h depth $W/bdeep x)"
/bb/h mkdeep $W/fdeep 200 x; /bb/h rlimit-nofile 64 /bin/rm -r $W/fdeep >$W/o 2>$E; echo "200 levels with 64 descriptors: rc=$?, levels left $(/bb/h depth $W/fdeep x), stderr $($B wc -l < $E) line(s) ending: $($B tail -c 60 $E | $B tr '\n' '|')"
/bin/rm -rf $W/fdeep
for s in 8192 1024 512 256 64; do
  /bb/h mkdeep $W/sdeep$s 4096 x; ( ulimit -s $s; /bin/rm -r $W/sdeep$s ) >$W/o 2>$E; echo "4096 levels with a ${s} kB stack: rc=$? (139 = SIGSEGV), levels left $(/bb/h depth $W/sdeep$s x): $(first $E | $B cut -c1-80)"
  /bin/rm -rf $W/sdeep$s
done
N255=$($B printf '%0255d' 7)
/bb/h mkdeep $W/wdeep 3000 $N255
/bin/rm -r $W/wdeep >$W/o 2>$E; echo "3000 levels of 255-byte names (768 kB path): rc=$?, levels left $(/bb/h depth $W/wdeep $N255)"
/bb/h mkdeep $W/wdeep2 4200 $N255
/bin/rm -r $W/wdeep2 >$W/o 2>$E; echo "4200 levels of 255-byte names: rc=$?, levels left $(/bb/h depth $W/wdeep2 $N255), stderr $($B wc -l < $E) line(s), $($B wc -c < $E) bytes, ending: $($B tail -c 50 $E | $B tr '\n' '|')"
/bb/h mkdeep $W/pdeep 30 $N255
/bb/h indeep $W/pdeep 30 $N255 /bin/pwd >$W/o 2>$E; echo "pwd in a directory whose path is $((30*256)) bytes: rc=$? stdout $($B wc -c < $W/o) bytes, stderr: $(first $E)"
/bb/h indeep $W/pdeep 30 $N255 /bb/busybox pwd >$W/o 2>$E; echo "busybox pwd there: rc=$? stdout $($B wc -c < $W/o) bytes"
/bb/h indeep $W/pdeep 30 $N255 /bin/ls -l >$W/o 2>$E; echo "ls -l there: rc=$? $($B cat $W/o)"
/bb/h indeep $W/pdeep 30 $N255 /bin/sh -c 'touch t && cp f g && mv g h && ln -s h l && mkdir -p m/n && rm -r m h l t && cd .. && pwd' >$W/o 2>$E; echo "touch, cp, mv, ln, mkdir -p, rm there, then cd .. and pwd in the shell: rc=$? $(first $E)"
/bin/rm -rf $W/pdeep

say "paths at and beyond PATH_MAX (4096 bytes with the NUL)"
cd $W; P=$W/long; $B mkdir $P; cd $P
seg=$($B printf '%0200d' 1); i=0; while [ $i -lt 19 ]; do $B mkdir $seg; cd $seg; i=$((i+1)); done   # 19*201 = 3819 bytes below $P
base="$P$($B printf "/$seg%.0s" 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19)"
pad() { $B printf "%0${1}d" 3; }
for total in 4094 4095 4096 4097 5000; do
  n=$((total - ${#base} - 1)); [ $n -gt 255 ] && { path="$base/$(pad 200)/$(pad $((n-201)))"; $B mkdir -p "$base/$(pad 200)" 2>/dev/null; } || path="$base/$(pad $n)"
  for t in "touch" "ls" "ls -l" "cat" "chmod 600" "chown 0" "rm" "rm -rf" "mkdir" "mkdir -p"; do
    /bin/$t "$path" >$W/o 2>$W/e; rc=$?
    $B printf 'path of %s bytes: %-10s rc=%s %s\n' ${#path} "$t" $rc "$($B tail -c 60 $W/e | $B tr '\n' '|')"
  done
  /bin/cp /etc/passwd "$path" 2>$W/e; $B printf 'path of %s bytes: %-10s rc=%s %s\n' ${#path} "cp to" $? "$($B tail -c 60 $W/e | $B tr '\n' '|')"
  /bin/mv "$path" "$path.m" 2>$W/e; $B printf 'path of %s bytes: %-10s rc=%s %s\n' ${#path} "mv" $? "$($B tail -c 60 $W/e | $B tr '\n' '|')"
  /bin/ln -s x "$path" 2>$W/e; $B printf 'path of %s bytes: %-10s rc=%s %s\n' ${#path} "ln -s" $? "$($B tail -c 60 $W/e | $B tr '\n' '|')"
done
cd "$base"; /bin/pwd >$W/o 2>$W/e; echo "pwd in a 3.8 kB directory: rc=$? ($($B wc -c < $W/o) bytes)"
cd $W; /bin/rm -rf $P; echo "rm -rf of the whole long tree: rc=$? exists after: $([ -e $P ] && echo yes || echo no)"

say "huge directory: 100000 entries"
$B mkdir $W/huge; cd $W/huge; $B seq 1 100000 | $B xargs $B touch; cd $W
s=$($B date +%s); /bin/ls $W/huge > $W/o 2>$W/e; rc=$?; echo "ls: rc=$rc lines=$($B wc -l < $W/o) in $(( $($B date +%s) - s )) s"
$B ls -1 $W/huge > $W/o2; $B cmp $W/o $W/o2 && echo "ls output identical to busybox ls -1 (same order)"
/bin/ls -l $W/huge > $W/o 2>$W/e; echo "ls -l: rc=$? lines=$($B wc -l < $W/o)"
/bin/ls -la $W/huge | $B head -3 > /dev/null; echo "ls -la | head -3: done"
s=$($B date +%s); /bin/rm -r $W/huge 2>$W/e; rc=$?; echo "rm -r: rc=$rc in $(( $($B date +%s) - s )) s, exists after: $([ -e $W/huge ] && echo yes || echo no) $(first $W/e)"
$B mkdir /tmp/huge; cd /tmp/huge; $B seq 1 20000 | $B xargs $B touch; $B mkdir sub; cd sub; $B seq 1 2000 | $B xargs $B touch; cd $W
/bin/rm -r /tmp/huge 2>$W/e; echo "rm -r of 22000 entries on the image's overlay filesystem: rc=$? exists after: $([ -e /tmp/huge ] && echo yes || echo no) $(first $W/e)"

say "special files and big files"
cd $W; $B mkdir sp; cd sp; $B mkfifo fifo; /bb/h mksock sock; $B truncate -s 5G sparse; echo x > reg
/bin/ls -l > $W/o; $B cat $W/o
$B timeout 5 /bin/cp fifo out1 2>$E; echo "cp fifo out1: rc=$? $(first $E) made: $([ -e out1 ] && echo yes || echo no)"
$B timeout 5 /bin/cat fifo >/dev/null 2>$E; echo "cat fifo (no writer; busybox blocks too): rc=$? (143 = still blocked after 5 s)"
$B timeout 5 /bin/cp reg fifo 2>$E; echo "cp reg fifo (no reader): rc=$? (143 = blocked)"
$B timeout 5 /bin/cp /dev/zero zero 2>$E; echo "cp /dev/zero zero on a 64 MB tmpfs: rc=$? $(first $E) size left: $($B stat -c %s zero 2>&1)"
/bin/rm zero
$B timeout 60 /bin/cp sparse copy 2>$E; echo "cp of a 5 GB sparse file to a 64 MB tmpfs: rc=$? $(first $E) partial copy left: $($B stat -c %s copy 2>&1) bytes"
/bin/rm -f copy
( /bb/h rlimit-fsize 1000 /bin/cp /bin/kcontaineros big ) 2>$E; echo "cp under a 1000-byte file size limit: rc=$? $(first $E) left: $($B stat -c %s big 2>&1) bytes"
( /bb/h rlimit-fsize 1000 /bin/sh -c '/bin/cat /bin/kcontaineros > big2' ) 2>$E; echo "cat under the same limit: rc=$? $(first $E)"
/bin/cp /dev/null devcopy; echo "cp /dev/null devcopy: rc=$? -> $($B stat -c '%F %s' devcopy)"
/bin/cp /dev/tty ttycopy 2>$E; echo "cp /dev/tty ttycopy (no terminal): rc=$? $(first $E)"
/bin/cp /proc/self/status st; echo "cp /proc/self/status st: rc=$? $($B wc -c < st) bytes"
/bin/cp /proc/self/mem memcopy 2>$E; echo "cp /proc/self/mem: rc=$? $(first $E)"
cd $W; /bin/rm -r sp

say "files that change while a tool runs"
cd $W; viol=0; ok=0; fail=0; n=0
while [ $n -lt 150 ]; do n=$((n+1))
  $B mkdir -p $W/busy/s; for i in 1 2 3 4 5 6 7 8 9 10; do : > $W/busy/f$i; : > $W/busy/s/g$i; done
  ( i=0; while [ -d $W/busy ]; do i=$((i+1)); : > $W/busy/s/new$i; : > $W/busy/new$i; done ) 2>/dev/null & A=$!
  /bin/rm -r $W/busy 2>$W/e; rc=$?
  if [ $rc = 0 ]; then ok=$((ok+1)); [ -e $W/busy ] && { sleep 0; [ -e $W/busy ] && viol=$((viol+1)); }; else fail=$((fail+1)); [ -s $W/e ] || viol=$((viol+1)); fi
  $B kill $A 2>/dev/null; wait $A 2>/dev/null; $B rm -rf $W/busy
done
echo "rm -r of a directory another process keeps filling, $n rounds: exit 0 and gone $ok, exit 1 with a message $fail, exit 0 but still there / exit 1 silent: $viol"
$B tail -1 $W/e
$B mkdir $W/churn; ( while [ -d $W/churn ]; do for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do : > $W/churn/c$i; done; $B rm -f $W/churn/c*; done ) 2>/dev/null & A=$!
n=0; bad=0; while [ $n -lt 300 ]; do n=$((n+1)); /bin/ls -l $W/churn >$W/o 2>$W/e; rc=$?; [ $rc = 0 ] && [ ! -s $W/e ] || { bad=$((bad+1)); $B cp $W/e $W/e.keep; }; done
echo "ls -l of a directory whose entries come and go, $n runs: runs with an error or a message: $bad $([ -f $W/e.keep ] && first $W/e.keep)"
$B rmdir $W/churn 2>/dev/null; $B kill $A 2>/dev/null; wait $A 2>/dev/null; $B rm -rf $W/churn
echo start > $W/grow; ( i=0; while [ $i -lt 20000 ]; do echo line$i >> $W/grow; i=$((i+1)); done ) & A=$!
/bin/cp $W/grow $W/grow.copy; rc=$?; wait $A
echo "cp of a file being appended to: rc=$rc; the copy ($($B wc -c < $W/grow.copy) bytes) is a prefix of the file ($($B wc -c < $W/grow) bytes): $($B head -c $($B wc -c < $W/grow.copy) $W/grow | $B cmp -s - $W/grow.copy && echo yes || echo NO)"

say "mkdir -p under umask 0300 against a directory/symlink flip (the chmod of a new parent is by path)"
cd $W; $B mkdir $W/mv
for impl in /bin/mkdir "$B mkdir"; do hits=0; n=0
while [ $n -lt ${MKROUNDS:-600} ]; do n=$((n+1))
  $B rm -rf $W/mt; $B mkdir $W/mt; $B chmod 500 $W/mv; $B ln -s $W/mv $W/mt/pl
  /bb/h flip $W/mt/p $W/mt/pl & F=$!
  ( umask 0300; $impl -p $W/mt/p/q ) 2>/dev/null
  $B kill -9 $F; wait $F 2>/dev/null
  m=$($B stat -c %a $W/mv); [ "$m" = 500 ] || { hits=$((hits+1)); [ $hits = 1 ] && echo "round $n: mode of the directory outside the operand changed from 500 to $m"; }
done
echo "$impl -p flip, $n rounds: rounds in which a directory outside the operand was chmod-ed: $hits"
done
echo; echo "== done"
