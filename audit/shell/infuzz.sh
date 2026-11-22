#!/bb/busybox sh
# Runs inside the container as PID 1 (busybox sh, no init). Reads a tar of
# inputs on stdin, runs each through kcos /bin/sh as a file, on stdin and
# (when it can be an argument) with -c, and prints "NAME MODE STATUS" per
# run. Output of the runs is thrown away, except the start of stderr when
# the status says the shell died.
B=/bb/busybox
LIMIT=${LIMIT:-5}
$B mkdir -p /in /tmp/run && $B tar x -C /in
ulimit -f 2048        # 1 MB files at most
ulimit -v 1048576     # 1 GB of address space: a blow-up fails as "out of memory" (status 101)
E="$B env -i PATH=/usr/local/bin:/usr/bin:/bin:/sbin HOME=/tmp"
cd /tmp/run
for f in /in/*; do
  n=${f##*/}
  for mode in file stdin c; do
    $B rm -f /tmp/mark
    case $mode in
      file)  $E $B timeout -s KILL $LIMIT /bin/sh $f a 'b c' >/dev/null 2>/tmp/err </dev/null; r=$?;;
      stdin) $E $B timeout -s KILL $LIMIT /bin/sh <$f >/dev/null 2>/tmp/err; r=$?;;
      c)     case $n in *.c) ;; *) continue;; esac
             src=$($B cat $f; echo x); src=${src%x}
             $E $B timeout -s KILL $LIMIT /bin/sh -c "$src" a 'b c' >/dev/null 2>/tmp/err </dev/null; r=$?;;
    esac
    kill -9 -1 2>/dev/null
    # Every input starts with a line that creates /tmp/mark. A script file or
    # -c string that is refused as a whole must not have created it.
    flag=
    case $mode in file|c) [ -e /tmp/mark ] && $B grep -q '^sh: syntax error' /tmp/err && flag=" RAN-THEN-SYNTAX-ERROR";; esac
    case $r in
      101|13[0-9]|14[0-9]|15[0-9]) echo "$n $mode $r $($B head -c 120 /tmp/err | $B base64 -w0)$flag";;
      *) echo "$n $mode $r -$flag";;
    esac
    cd /tmp/run 2>/dev/null || { $B mkdir -p /tmp/run; cd /tmp/run; }
  done
  case $n in *00) $B rm -rf /tmp/run; $B mkdir -p /tmp/run; cd /tmp/run;; esac
done
echo DONE
