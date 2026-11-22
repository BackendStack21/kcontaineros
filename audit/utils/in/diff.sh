# Inside the container (busybox sh). Differential: every case is run twice
# on identical freshly generated trees, once with the kcontaineros utility
# (/bin/NAME) and once with busybox. Compared: exit status (0 or not),
# standard output, and the resulting tree (type, mode, size, link count,
# link target, content hash, and whether the mtime is still the old one).
# Output: one line per case, SAME or DIFF, with both exits and messages.
B=/bb/busybox; W=/work; R=/tmp/r; $B mkdir -p $R
N255=$($B printf '%0255d' 7)
NL=$($B printf 'new\nline')
CTL=$($B printf 'ctl\001\033[31mred\007')
HI=$($B printf 'hi\377\376bit')
MODE=$1   # init or control, for the log only

mk() { # the corpus, built in the current directory
  echo data > a; echo two > b; echo x > 'sp ace'; echo x > "$NL"; echo x > "$CTL"; echo x > "$HI"
  echo dash > ./-dash; echo x > ./--; echo x > ./-rf; echo x > "$N255"
  $B mkdir d d/sub empty ro ro/in; echo 1 > d/f1; echo 2 > d/sub/f2; echo h > d/.hidden; echo r > ro/f; echo r > ro/in/g
  $B ln -s a link; $B ln -s d dlink; $B ln -s nowhere dangling; $B ln -s loop2 loop1; $B ln -s loop1 loop2; $B ln -s self self
  $B mkfifo fifo; /bb/h mksock sock; $B ln a hard
  echo s > noread; echo s > suid; echo s > sgid; $B mkdir unread sticky; echo u > unread/f
  $B truncate -s 3G sparse
  $B touch -d '2000-01-01 00:00:00' a b d empty link noread fifo
  $B chmod 4755 suid; $B chmod 2755 sgid; $B chmod 1777 sticky; $B chmod 000 noread unread; $B chmod 555 ro ro/in
}
manifest() {
  $B find . -mindepth 1 2>&1 | LC_ALL=C $B sort | while IFS= read -r p; do
    [ -e "$p" ] || [ -L "$p" ] || { echo "?? $p"; continue; }
    t=$($B stat -c '%F|%a|%h|%u:%g' "$p" 2>&1)
    case "$t" in
      "regular file"*|"regular empty file"*)
        s=$($B stat -c %s "$p"); if [ "$s" -gt 1048576 ]; then h="size=$s blocks=$($B stat -c %b "$p")"; else h="size=$s $($B md5sum < "$p" 2>&1 | $B cut -c1-12)"; fi;;
      "symbolic link"*) h="-> $($B readlink "$p")";;
      *) h="";;
    esac
    y=$($B stat -c %y "$p" | $B cut -c1-4); [ "$y" = 2000 ] && y=old || y=new
    echo "$p|$t|$h|$y"
  done
}
unlock() { $B chmod -R u+rwx $W/k $W/b 2>/dev/null; }
N=0; ND=0
# c TOOL ARGS...   ($PRE: commands run in the tree first; $REDIR: appended to the command; $STDIN: its input)
c() {
  tool=$1; shift
  for impl in k b; do
    cd $W; unlock; $B rm -rf $W/$impl; $B mkdir $W/$impl
    : > $R/$impl.out; : > $R/$impl.err; : > $R/$impl.rc
    case $impl in k) cmd=/bin/$tool;; b) cmd="$B $tool";; esac
    ( # a subshell, so that a umask or cd in $PRE ends with the case
      cd $W/$impl; mk
      [ -n "$PRE" ] && eval "$PRE"
      if [ -n "$REDIR" ]; then
        eval "$B timeout 20 $cmd \"\$@\" $REDIR" 2>$R/$impl.err; echo $? > $R/$impl.rc
      else
        $B timeout 20 $cmd "$@" < ${STDIN:-/dev/null} >$R/$impl.out 2>$R/$impl.err; echo $? > $R/$impl.rc
      fi
    )
    $B sed -i "s|$W/$impl|$W/X|g" $R/$impl.out $R/$impl.err   # the two trees differ only in this name
    cd $W/$impl; manifest > $R/$impl.man 2>&1
    $B find $W/$impl -type f -size +1024k -exec $B rm -f {} + 2>/dev/null   # leave room for the other run
  done
  cd $R
  N=$((N+1))
  kr=$($B cat k.rc); br=$($B cat b.rc); d=""
  [ "$kr" = 0 ] && kz=0 || kz=1; [ "$br" = 0 ] && bz=0 || bz=1
  [ $kz = $bz ] || d="$d exit"
  $B cmp -s k.out b.out || d="$d stdout"
  $B cmp -s k.man b.man || d="$d tree"
  ke=$($B head -c 160 k.err | $B tr '\n\t' '| ' | $B tr -c ' -~' '?'); be=$($B head -c 160 b.err | $B tr '\n\t' '| ' | $B tr -c ' -~' '?')
  args=$(for x in "$@"; do $B printf '[%s] ' "$x"; done | $B tr '\n' '^' | $B tr -c ' -~' '?' | $B cut -c1-90)
  if [ -z "$d" ]; then
    $B printf 'SAME\t%s %s%s\tk=%s b=%s\tk: %s\tb: %s\n' "$tool" "$args" "${PRE:+ PRE{$PRE\}}${REDIR:+ $REDIR}" "$kr" "$br" "$ke" "$be"
  else
    ND=$((ND+1))
    $B printf 'DIFF(%s)\t%s %s%s\tk=%s b=%s\tk: %s\tb: %s\n' "${d# }" "$tool" "$args" "${PRE:+ PRE{$PRE\}}${REDIR:+ $REDIR}" "$kr" "$br" "$ke" "$be"
    case "$d" in *tree*) $B diff k.man b.man | $B grep '^[+-][^+-]' | $B tr -c ' -~\n' '?' | $B head -8 | $B sed 's/^/\t\ttree: /';; esac
    case "$d" in *stdout*) $B printf '\t\tk.out: %s\n\t\tb.out: %s\n' "$($B head -c 200 k.out | $B od -An -c | $B tr -s ' \n' ' ' | $B cut -c1-200)" "$($B head -c 200 b.out | $B od -An -c | $B tr -s ' \n' ' ' | $B cut -c1-200)";; esac
  fi
  PRE=""; REDIR=""; STDIN=""
}
echo "# mode=$MODE"
echo abc > $R/stdin.txt

echo "== cat"
c cat a; c cat a b; c cat; STDIN=$R/stdin.txt c cat; STDIN=$R/stdin.txt c cat -; STDIN=$R/stdin.txt c cat a - b
c cat nonexist a; c cat a nonexist; c cat d; c cat link; c cat dangling; c cat loop1; c cat noread; c cat unread/f
c cat -- -dash; c cat ./--; c cat -dash; c cat -- --; c cat "sp ace" "$NL" "$CTL" "$HI" "$N255"; c cat sock; c cat /dev/null; c cat ""
c cat a/; c cat a/x; c cat "${N255}x"
REDIR='> /dev/null' c cat sparse
REDIR='> /dev/full' c cat a; REDIR='>&-' c cat a; REDIR='<&-' c cat; REDIR='> /dev/full' c cat nonexist a
REDIR='>> a' c cat a
REDIR='> b' c cat a b

echo "== chmod"
c chmod 644 a; c chmod 000 a; c chmod 755 link; c chmod 644 dangling; c chmod 700 d; c chmod 4755 a; c chmod 7777 a
c chmod 644 a nonexist b; c chmod 644 loop1; c chmod 600 noread; c chmod 0 d; c chmod 755 unread/f; c chmod 644 -- -dash
c chmod 644 ./-dash; c chmod 644 "$NL" "$CTL" "$HI" "$N255"; c chmod 644 ""; c chmod 777 fifo sock; c chmod 644 a/
c chmod 1 a; c chmod 12 a; c chmod 0644 a

echo "== chown"
c chown 0 a; c chown 0:0 a; c chown 1234 a; c chown 1234:5678 a; c chown 0:5678 a; c chown 1234:5678 link; c chown 1234:5678 dangling
c chown 1234:5678 d; c chown 1234:5678 a nonexist b; c chown 1234:5678 loop1; c chown 1234:5678 suid; c chown 65534:65534 "$NL" fifo sock
c chown 4294967294 a; c chown 0:4294967294 a; c chown 1234:5678 -- -dash; c chown 1234:5678 ""

echo "== cp"
c cp a new; c cp a b; c cp a d; c cp a d/; c cp a b d; c cp a b empty/; c cp a nonexist/x; c cp a a; c cp a ./a; c cp a hard; c cp a link; c cp link a
c cp link new; c cp dangling new; c cp a dangling; c cp d new; c cp d empty; c cp fifo new; c cp sock new; c cp /dev/null new; c cp /dev/null a
c cp suid new; c cp sgid new; c cp noread new; c cp a noread; c cp a unread/x; c cp a ro/x; c cp a ro/f; c cp sparse new
# busybox cp, given capabilities, replaces /dev/full with a regular file: under init only
[ "$MODE" = init ] && c cp a /dev/full
c cp "sp ace" "$NL"; c cp "$CTL" "$HI"; c cp -- -dash new; c cp -dash new; c cp a ""; c cp "" new; c cp a b c; c cp a d/sub/../new
c cp loop1 new; c cp a loop1; c cp a self; c cp d/ new; c cp a/ new; c cp a new/; c cp a b nonexist/; c cp nonexist a b d; c cp a nonexist b d
c cp a d d/sub; c cp d/f1 d/sub/f2 .; c cp d/f1 a ..; c cp a fifo; c cp a "$N255"; c cp a "${N255}x"; c cp "$N255" new; c cp a b a d
c cp a dlink; c cp a dlink/; c cp empty new; c cp a empty/.; c cp a empty/..; c cp . new; c cp .. new; c cp d/. new; c cp a/. new
PRE='umask 0' c cp a new; PRE='umask 077' c cp a new; PRE='umask 0; $B chmod 777 a' c cp a new; PRE='$B chmod 600 a; umask 0' c cp a b
PRE='$B chmod 6777 suid; umask 0' c cp suid new; PRE='$B chmod 6777 suid; umask 0' c cp suid b
PRE='$B chmod 444 b' c cp a b; PRE='$B chmod 000 b' c cp a b
PRE='$B chmod 1755 a; umask 0' c cp a new; PRE='$B chmod 7777 a; umask 0' c cp a new; c cp a suid; c cp a sticky; c cp suid sgid
REDIR='> /dev/full' c cp a new; REDIR='>&- 2>&-' c cp a new

echo "== mv"
c mv a new; c mv a b; c mv a d; c mv a d/; c mv a b d; c mv d new; c mv d empty; c mv d d; c mv d d/sub; c mv a a; c mv a hard; c mv link new
c mv dangling new; c mv a dangling; c mv a link; c mv a nonexist/x; c mv fifo new; c mv sock new; c mv a d/f1; c mv d a; c mv a empty; c mv d/ new
c mv a new/; c mv a/ new; c mv a /tmp/kcos-audit-utils-x; c mv -- -dash new; c mv -dash new; c mv unread new; c mv a unread/x; c mv a ro/x
c mv ro/f new; c mv ro new; c mv "sp ace" "$NL"; c mv "$CTL" "$HI"; c mv a ""; c mv "" new; c mv a b c; c mv nonexist a b d; c mv a nonexist b d
c mv loop1 new; c mv a loop1; c mv empty d/sub; c mv d/sub empty; c mv empty a; c mv a .; c mv a ..; c mv . new; c mv .. new; c mv d/. new
c mv empty d; c mv d/sub .; c mv dlink new; c mv dlink/ new; c mv a dlink; c mv d dlink; c mv a "${N255}x"; c mv suid new; c mv noread new
PRE='$B mkdir empty/d' c mv d empty; PRE='$B mkdir empty/d; echo z > empty/d/z' c mv d empty; PRE='echo z > empty/a' c mv a empty; PRE='$B mkdir empty/a' c mv a empty
PRE='$B chmod 444 b' c mv a b; PRE='$B chmod 000 b' c mv a b

echo "== ln"
c ln a new; c ln -s a new; c ln -s nonexist new; c ln a b; c ln -s a b; c ln nonexist new; c ln d new; c ln -s a d; c ln a d; c ln link new
c ln dangling new; c ln -s "" new; c ln -s a ""; c ln -- -dash new; c ln -s -- -dash new; c ln a /tmp/kcos-audit-utils-l; c ln -s a nonexist/x
c ln a ro/x; c ln -s a ro/x; c ln -s "$CTL" "$NL"; c ln a "${N255}x"; c ln -s a dangling; c ln -s a link; c ln fifo new; c ln suid new
c ln -s a/ new; c ln a/ new; c ln a new/; c ln -s d dlink; c ln -s . new; c ln -ss a new; c ln -s -s a new; c ln loop1 new

echo "== mkdir"
c mkdir new; c mkdir new/x; c mkdir -p new/x/y; c mkdir -p d/sub; c mkdir -p a; c mkdir -p a/x; c mkdir d; c mkdir -p d; c mkdir a
c mkdir -p new/../new2/./x//y/; c mkdir -p dlink/x; c mkdir -p dangling/x; c mkdir -p dangling; c mkdir dangling; c mkdir -p loop1/x; c mkdir -p link/x
c mkdir new1 new2 d new3; c mkdir -p new1 a/x new3; c mkdir -p unread/x; c mkdir -p ro/x; c mkdir ro/x; c mkdir "$NL dir" "$CTL dir"
c mkdir -- -p; c mkdir -p -- -p/x; c mkdir -p ""; c mkdir ""; c mkdir -p /; c mkdir -p .; c mkdir -p ..; c mkdir -p ./new/; c mkdir -p new//; c mkdir new/
c mkdir -p "$N255/$N255"; c mkdir -p "${N255}x/y"; c mkdir "${N255}x"; c mkdir -p .///new///x//; c mkdir -pp new/x; c mkdir -p -p new/x
c mkdir -p dlink; c mkdir -p fifo/x; c mkdir -p new new; c mkdir new new
PRE='umask 0' c mkdir new; PRE='umask 0' c mkdir -p new/x; PRE='umask 077' c mkdir -p new/x; PRE='umask 0777' c mkdir -p new/x/y
PRE='umask 0222' c mkdir -p new/x/y; PRE='umask 0333' c mkdir -p new/x; PRE='umask 0777' c mkdir new; PRE='umask 0300' c mkdir -p d/sub/n1/n2

echo "== rm"
c rm a; c rm a b nonexist; c rm nonexist a b; c rm -f nonexist; c rm -f nonexist a; c rm d; c rm -f d; c rm empty; c rm -r d; c rm -rf d empty a
c rm -r empty; c rm -r dlink; c rm -r dlink/; c rm -rf dlink/; c rm -r link dangling loop1 self; c rm link/; c rm -r fifo sock; c rm -r unread; c rm -rf unread
c rm -r ""; c rm -rf ""; c rm -rf -- -dash --; c rm -- -rf; c rm ./-rf; c rm -r d/sub/../sub; c rm noread; c rm -f noread; c rm -r ro; c rm -rf ro
c rm -r ro/in; c rm ro/f; c rm -f ro/f; c rm -r d/; c rm -r empty/; c rm -r d//; c rm a/; c rm -f a/; c rm a/x; c rm -f a/x; c rm -r a/x; c rm -rf nonexist/x
c rm "sp ace" "$NL" "$CTL" "$HI" "$N255"; c rm "${N255}x"; c rm -f "${N255}x"; c rm -r d d; c rm -rf d d; c rm a a; c rm -f a a; c rm -r d/sub d
c rm -r d d/sub; c rm -rf d d/sub; c rm -fr d; c rm -r -f d; c rm -rr d; c rm -R d; c rm -r sticky suid sgid; c rm sparse; c rm hard; c rm -r loop1/x; c rm -rf loop1/x
PRE='$B chmod 000 d/sub' c rm -r d; PRE='$B chmod 000 d/sub' c rm -rf d; PRE='$B chmod 000 empty' c rm -r empty; PRE='$B chmod 555 d' c rm -r d
PRE='$B chmod 555 d/sub' c rm -rf d; PRE='$B chmod 111 d' c rm -r d; PRE='$B chmod 444 d' c rm -r d; PRE='$B chmod 000 a' c rm a
PRE='$B mkdir -p d/x1/x2/x3/x4/x5; echo z > d/x1/x2/x3/x4/x5/z; $B chmod 555 d/x1/x2/x3' c rm -rf d

echo "== touch"
c touch new; c touch a; c touch d; c touch dangling; c touch link; c touch nonexist/x; c touch new1 new2; c touch noread; c touch fifo; c touch loop1
c touch ""; c touch -- -dash2; c touch -dash2; c touch a nonexist/x b; c touch ro/x; c touch ro/f; c touch unread/f; c touch unread/x; c touch a/; c touch new/
c touch "$NL 2" "$CTL 2"; c touch "${N255}x"; c touch sock; c touch /dev/null; c touch empty/. ; c touch .
PRE='umask 0' c touch new; PRE='umask 0777' c touch new; PRE='$B chmod 444 a' c touch a

echo "== echo"
c echo; c echo a b; c echo -n; c echo -n x; c echo -e 'a\tb\n'; c echo -e '\0101\x41\101'; c echo -E 'a\tb'; c echo -ne 'x\n'; c echo -en x; c echo -neE 'a\n'
c echo --; c echo -; c echo -x; c echo -e '\c' x; c echo -e 'a\cb' c; c echo -e '\\'; c echo -e '\'; c echo -e 'a\'; c echo -e '\0'; c echo -e '\07778'; c echo -e '\xg'
c echo -e '\x4'; c echo -e '\e[0m'; c echo -e; c echo -n -e 'x\n'; c echo -e -n '\n'; c echo a -n; c echo -nn x; c echo -e '\x'; c echo -e '\0777'; c echo -e '\x414'
c echo -e '\a\b\f\v\r'; c echo -e '\q\z\8\9'; c echo -e '\1\12\123'; c echo -ee -E '\n'; c echo -eE -e '\n'; c echo -n -n -n x; c echo '' ''; c echo -e '' '\c' ''
c echo -- -n; c echo -nx; c echo -e '\0000101'; c echo -e 'A'; c echo "$CTL" "$HI"; c echo -E -e '\\n'; c echo -e '\\\\'; c echo -e '\x0\x00a'
REDIR='> /dev/full' c echo x; REDIR='>&-' c echo x; REDIR='> /dev/full' c echo -n; REDIR='> /dev/full' c echo -n ''

echo "== env"
c env -i; c env -i A=1; c env -i A=1 A=2; c env -i A=1 B=2 A=3; c env -i A=1 /bin/env; c env -i nonexist; c env -i $W; c env -i ./a; c env -i - A=1
c env -i A=1 -u A; c env -i =x; c env -i A=; c env -i A=1 /bin/env -u A; c env -i -- A=1; c env -i A=1 /bin/env -u A B=2 /bin/env; c env -i A==; c env -i A=1 /bin/env -u A=1
c env -i A=1 AB=2 /bin/env -u AB; c env -i AB=1 A=2 /bin/env -u A; c env - A=1; c env -i -i; c env -i A=1 /bin/env -i; c env -i /bin/echo hi; c env -i A=1 /bin/env -u ""
c env -i "A B=1" "$NL=2"; c env -i A=1 /bin/env -- B=2; c env -i A=1 /bin/env -u A -u A -u B; c env -u; c env -i -u
REDIR='> /dev/full' c env -i A=1; REDIR='>&-' c env -i A=1

echo "== pwd"
c pwd; PRE='cd d/sub' c pwd; PRE='cd dlink' c pwd; PRE='cd "$NL dir" 2>/dev/null || { $B mkdir "$NL dir"; cd "$NL dir"; }' c pwd
PRE='$B mkdir gone; cd gone; $B rmdir ../gone' c pwd
REDIR='> /dev/full' c pwd; REDIR='>&-' c pwd

echo "== uname"
c uname; c uname -s; c uname -n; c uname -r; c uname -m; c uname -sn; c uname -s -n; c uname -snrm; c uname -a; c uname -v; c uname -o; c uname x
REDIR='> /dev/full' c uname; REDIR='>&-' c uname -a

echo "== true false"
c true; c false; c true x; c false x; REDIR='> /dev/full' c true; REDIR='>&-' c false

echo "== kill sleep (only forms that touch no process)"
c kill; c kill -0 $$; c kill -0 2147483646; c kill -s 0 $$; c kill -l; c kill -0; c kill -0 $$ 2147483646; c kill -0 1; c kill -s HUP; c kill -TERM
c sleep 0; c sleep 0.01; c sleep; c sleep 0 0; c sleep 0s; c sleep 0m; c sleep 0h; c sleep 0d; c sleep x; c sleep 0.001s 0.001; c sleep -1; c sleep 1e-2; c sleep .01; c sleep 0.

echo "TOTAL cases=$N diff=$ND"
