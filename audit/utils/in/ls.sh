# Inside the container. ls against what busybox stat says about every entry.
B=/bb/busybox; W=/work; R=/tmp/r; $B mkdir -p $R
N255=$($B printf '%0255d' 7); CTL=$($B printf 'ctl\001\033[31mred\007'); HI=$($B printf 'hi\377\376bit')
$B mkdir $W/l; cd $W/l
echo data > a; echo x > 'sp ace'; echo x > "$CTL"; echo x > "$HI"; echo x > ./-dash; echo x > ./--; echo x > "$N255"; echo h > .hidden; : > empty
$B mkdir d d/sub .hd unread nox sticky; echo 1 > d/f1; echo 1 > unread/f; echo 1 > nox/f
$B ln -s a link; $B ln -s d dlink; $B ln -s nowhere dangling; $B ln -s loop2 loop1; $B ln -s loop1 loop2; $B ln -s "$CTL" ctllink; $B ln a hard
$B ln -s "$($B printf '%04000d' 1)" longlink
$B mkfifo fifo; /bb/h mksock sock; $B truncate -s 5G sparse; echo s > suid; echo s > sgid; echo s > SUID; $B chmod 4755 suid; $B chmod 2755 sgid; $B chmod 4644 SUID; $B chmod 1777 sticky
$B chmod 1776 .hd; $B chmod 000 unread empty; $B chmod 644 nox
pass=0; fail=0
ok() { if $B cmp -s $R/got $R/want; then pass=$((pass+1)); else fail=$((fail+1)); echo "MISMATCH: $1"; $B diff $R/want $R/got | $B head -6 | $B tr -c ' -~\n' '?' | $B cut -c1-200; fi; }
long() { # expected ls -l line for each name on stdin, relative to directory $1
  while IFS= read -r n; do
    l=$($B stat -c '%A %u %g %s' "$1/$n")
    if [ -L "$1/$n" ]; then echo "$l $n -> $($B readlink "$1/$n")"; else echo "$l $n"; fi
  done
}
names() { $B find "$1" -mindepth 1 -maxdepth 1 | $B sed "s|^$1/||" | LC_ALL=C $B sort; }
names . | $B grep -v '^\.' > $R/want; /bin/ls > $R/got; ok "ls"
names . > $R/want; /bin/ls -a > $R/got; ok "ls -a (lists dot files; . and .. themselves are not shown)"
names . | $B grep -v '^\.' | long . > $R/want; /bin/ls -l > $R/got; ok "ls -l"
names . | long . > $R/want; /bin/ls -la > $R/got; ok "ls -la"
names . | long . > $R/want; /bin/ls -al > $R/got; ok "ls -al"; /bin/ls -a -l > $R/got; ok "ls -a -l"; /bin/ls -l -a -- . > $R/got; ok "ls -l -a -- ."
names d | long d > $R/want; /bin/ls -l d > $R/got; ok "ls -l d"; /bin/ls -l d/ > $R/got; ok "ls -l d/"; /bin/ls -l dlink > $R/got; ok "ls -l dlink (a link to a directory is listed as the directory)"
for f in a link dangling loop1 fifo sock sparse suid SUID sgid "$CTL" "$HI" "$N255" ctllink longlink -dash; do
  echo "$f" | long . > $R/want; /bin/ls -l -- "$f" > $R/got 2>&1; ok "ls -l -- $(echo "$f" | $B tr -c ' -~\n' '?' | $B cut -c1-30)"
  echo "$f" > $R/want; /bin/ls -- "$f" > $R/got 2>&1; ok "ls -- $(echo "$f" | $B tr -c ' -~\n' '?' | $B cut -c1-30)"
done
/bin/ls -l /dev/null /dev/zero > $R/got; { echo "$($B stat -c '%A %u %g %s' /dev/null) /dev/null"; echo "$($B stat -c '%A %u %g %s' /dev/zero) /dev/zero"; } > $R/want; ok "ls -l /dev/null /dev/zero"
{ echo "d:"; names d; echo; echo "sticky:"; names sticky; } > $R/want; /bin/ls d sticky > $R/got; ok "ls d sticky (headers)"
echo "passed $pass, mismatched $fail"
echo "-- exit status and messages"
t() { /bin/ls "$@" > $R/got 2> $R/err; rc=$?; $B printf '%-34s rc=%s stdout %s line(s); %s\n' "ls $*" $rc "$($B wc -l < $R/got)" "$($B head -c 150 $R/err | $B tr '\n' '|')"; }
t nonexist; t a nonexist d; t nonexist a; t -l nonexist a; t unread; t -l unread; t nox; t -l nox; t a/; t a/x; t dangling/; t loop1/x; t loop1/; t -l loop1/; t ""; t -l ""; t d d; t . .
t /proc/1/fd; t -l /proc/self/fd; t /proc/self/task; t -l /proc/self/exe; t -l /proc/self/root; t -l /proc/self/cwd; t /sys/kernel; t -l /dev; t -la /
echo "-- names with a newline (not on a terminal: printed as they are)"
$B mkdir $W/nl; echo x > "$W/nl/$($B printf 'one\ntwo')"; /bin/ls $W/nl | $B od -c | $B head -2
