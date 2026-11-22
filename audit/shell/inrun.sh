#!/bb/busybox sh
# Runs inside the container (busybox sh, no init): every /w/s/*.sh through
# kcos /bin/sh (k) and busybox sh (b), as a file, with -c and on stdin.
# Results go to /tmp/out and leave as a tar on stdout.
B=/bb/busybox
E="$B env -i PATH=/usr/local/bin:/usr/bin:/bin:/sbin HOME=/root"
LIMIT=${LIMIT:-10}
MODES=${MODES:-file c stdin}
$B mkdir -p /tmp/out
ulimit -f 512   # 256 kB: a script that feeds a file to itself must not fill the disk
for f in /w/s/*.sh; do
  n=${f##*/}; n=${n%.sh}
  for s in k b; do
    case $s in k) S=/bin/sh;; b) S="$B sh";; esac
    for mode in $MODES; do
      d=/tmp/run; $B rm -rf $d; $B mkdir $d; cd $d
      o=/tmp/out/$n.$s.$mode
      case $mode in
        file)  $E $B timeout -s KILL $LIMIT $S $f a1 'b 2' '' z >$o.o 2>$o.e </dev/null;;
        c)     src=$($B cat $f; echo x); src=${src%x}   # keeps the trailing newlines
               $E $B timeout -s KILL $LIMIT $S -c "$src" $f a1 'b 2' '' z >$o.o 2>$o.e </dev/null;;
        stdin) $E $B timeout -s KILL $LIMIT $S <$f >$o.o 2>$o.e;;
      esac
      echo $? >$o.r
      kill -9 -1 2>/dev/null   # whatever the script left running (this shell is PID 1)
      cd $d 2>/dev/null && $B grep -r '' . 2>/dev/null | $B sort >$o.f
      cd /
    done
  done
done
cd /tmp/out && $B tar c .
