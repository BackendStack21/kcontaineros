# Inside the container. A directory name is swapped with a symlink to a
# victim directory while rm -r runs. Counts the rounds in which rm deleted
# anything inside the victim, which is outside the operand tree.
#   $1 = k (kcontaineros rm) or b (busybox rm), $2 = variant, $3 = rounds
B=/bb/busybox; W=/work
impl=$1; variant=$2; rounds=${3:-300}
case $impl in k) RM=/bin/rm;; b) RM="$B rm";; esac
mkvictim() { $B mkdir -p $W/victim/keep; for i in 1 2 3 4 5 6 7 8; do echo precious > $W/victim/f$i; echo precious > $W/victim/keep/g$i; done; }
count() { $B find $W/victim -type f 2>/dev/null | $B wc -l; }
mktree() { # $W/t/x is a real directory with content; $W/t/xl a link to the victim
  $B rm -rf $W/t; $B mkdir -p $W/t/x/s1/s2 $W/t/x/s3
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do : > $W/t/x/a$i; : > $W/t/x/s1/b$i; : > $W/t/x/s1/s2/c$i; done
  $B ln -s $W/victim $W/t/xl
}
cd $W; mkvictim
lost=0; n=0; rc0=0
while [ $n -lt $rounds ]; do
  n=$((n+1))
  mktree
  /bb/h flip $W/t/x $W/t/xl & F=$!
  case $variant in
    slash)   $RM -rf $W/t/x/  2>/dev/null; rc=$?;;   # operand with a trailing slash
    plain)   $RM -rf $W/t/x   2>/dev/null; rc=$?;;   # the operand itself is swapped
    nested)  $RM -rf $W/t     2>/dev/null; rc=$?;;   # a directory below the operand is swapped
    relslash) cd $W/t; $RM -rf x/ 2>/dev/null; rc=$?; cd $W;;
  esac
  $B kill -9 $F; wait $F 2>/dev/null
  [ $rc = 0 ] && rc0=$((rc0+1))
  c=$(count)
  if [ "$c" != 16 ]; then lost=$((lost+1)); [ $lost = 1 ] && echo "first loss in round $n: $c of 16 victim files left, rm exit $rc"; $B rm -rf $W/victim; mkvictim; fi
done
echo "RESULT impl=$impl variant=$variant rounds=$n rounds-with-victim-files-deleted=$lost rm-exit-0=$rc0"
