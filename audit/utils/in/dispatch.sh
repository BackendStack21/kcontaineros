# Inside the container. argv[0] dispatch of /bin/kcontaineros: each case is
# execve("/bin/kcontaineros", ARGV) with exactly the argv shown (h argv).
B=/bb/busybox; K=/bin/kcontaineros
cd /tmp; echo data > f
BIG=$($B head -c 100000 /dev/zero | $B tr '\0' 'A')
C1=$($B printf 'ls\001'); C2=$($B printf '\001ls'); C3=$($B printf 'ls\377'); C4=$($B printf 'l\ns')
r() { # description, then argv
  d=$1; shift
  out=$($B timeout 10 /bb/h argv $K "$@" 2>&1 </dev/null); rc=$?
  $B printf '%-34s rc=%-3s %s\n' "$d" "$rc" "$(echo "$out" | $B head -c 150 | $B tr '\n' '|' | $B tr -c ' -~' '?')"
}
r "argc=0"
r "['']" ""
r "[ls f]" ls f
r "[/bin/ls f]" /bin/ls f
r "[./ls f]" ./ls f
r "[/nonexistent/dir/ls f]" /nonexistent/dir/ls f
r "[ls/ f]" ls/ f
r "[/]" /
r "[LS f]" LS f
r "['ls ' f]" "ls " f
r "[-ls f]" -ls f
r "[-sh -c 'echo hi']" -sh -c 'echo hi'
r "[sh -c 'echo hi']" sh -c 'echo hi'
r "[/x/sh -c 'echo hi']" /x/sh -c 'echo hi'
r "[ls\\001 f]" "$C1" f
r "[\\001ls f]" "$C2" f
r "[ls\\377 f]" "$C3" f
r "[l\\ns f]" "$C4" f
r "[100000 x A]" "$BIG"
r "[/100000 x A/ls f]" "/$BIG/ls" f
r "[--version]" --version
r "[--list]" --list
r "[kcontaineros]" kcontaineros
r "[kcontaineros --help]" kcontaineros --help
r "[kcontaineros -h]" kcontaineros -h
r "[kcontaineros --version]" kcontaineros --version
r "[kcontaineros -V]" kcontaineros -V
r "[kcontaineros --version extra]" kcontaineros --version extra
r "[kcontaineros --list extra]" kcontaineros --list extra
r "[kcontaineros --bogus]" kcontaineros --bogus
r "[kcontaineros -x]" kcontaineros -x
r "[kcontaineros '']" kcontaineros ""
r "[kcontaineros ls f]" kcontaineros ls f
r "[/a/b/kcontaineros ls f]" /a/b/kcontaineros ls f
r "[kcontaineros /bin/ls f]" kcontaineros /bin/ls f
r "[kcontaineros ../../x/ls f]" kcontaineros ../../x/ls f
r "[kcontaineros kcontaineros ls f]" kcontaineros kcontaineros ls f
r "[kcontaineros kcontaineros --version]" kcontaineros kcontaineros --version
r "[kcontaineros sh -c 'echo hi']" kcontaineros sh -c 'echo hi'
r "[kcontaineros true]" kcontaineros true
r "[kcontaineros false]" kcontaineros false
r "[kcontaineros nosuch]" kcontaineros nosuch
r "[kcontaineros init /bin/echo hi]" kcontaineros init /bin/echo hi
r "[kcontaineros init -- /bin/echo hi]" kcontaineros init -- /bin/echo hi
r "[kcontaineros init]" kcontaineros init
r "[kcontaineros /x/init /bin/echo hi]" kcontaineros /x/init /bin/echo hi
r "[init /bin/echo hi]" init /bin/echo hi
r "[/x/y/init -- /bin/echo hi]" /x/y/init -- /bin/echo hi
r "[init]" init
r "[init --]" init --
r "[INIT /bin/echo hi]" INIT /bin/echo hi
r "[kcontaineros.]" kcontaineros.
r "[kcontaineros/ ls]" kcontaineros/ ls
echo "== every applet name through each form (exit status of 'NAME --' style no-op where one exists)"
for a in $($K --list); do
  case $a in init) continue;; sh) args="-c :";; cat) args=/dev/null;; chmod) args="644 f";; chown) args="0 f";; cp) args="f g";; echo) args="";; env) args="-i";; false) args="";; kill) args="-0 $$";; ln) args="-s f l";; ls) args=f;; mkdir) args="-p m";; mv) args="g g2";; ps) args="";; pwd) args="";; rm) args="-f g";; sleep) args=0;; touch) args=f;; true) args="";; uname) args="";; esac
  for form in "$a" "/bin/$a" "kcontaineros $a" "kcontaineros /x/$a"; do
    $B rm -rf l g g2 m; echo data > f; echo data > g
    $B timeout 10 /bb/h argv $K $form $args >/dev/null 2>/tmp/err </dev/null; rc=$?
    $B printf '%-26s rc=%s %s\n' "[$form]" $rc "$($B head -c 100 /tmp/err | $B tr '\n' '|')"
  done
done
echo "== symlinks in the image all point at the binary"
for l in /bin/* /sbin/* /usr/bin/*; do $B printf '%s -> %s\n' "$l" "$($B readlink "$l")"; done | $B tr '\n' ' '; echo
echo "== output cannot be written"
for form in "--version" "-V" "--list" "--help" "-h" ""; do
  for redir in '>/dev/full' '>&-' '</dev/null >&- 2>&-'; do
    eval "$K $form $redir" 2>/tmp/err; rc=$?
    $B printf '%-44s rc=%s %s\n' "kcontaineros $form $redir" $rc "$($B head -c 100 /tmp/err | $B tr '\n' '|')"
  done
done
for t in "ls /" "ls -l /" "pwd" "env" "uname -a" "ps" "echo x" "echo -n x" "cat /etc/passwd" "echo" "sh -c 'echo x'" "sh -c 'pwd'" "sh -c 'command -v ls'"; do
  for redir in '>/dev/full' '>&-'; do
    eval "/bin/$t $redir" 2>/tmp/err; rc=$?
    $B printf '%-44s rc=%s %s\n' "$t $redir" $rc "$($B head -c 100 /tmp/err | $B tr '\n' '|')"
  done
done
echo "== more output than one buffer, to a pipe that closes (SIGPIPE) and to a full tmpfs"
$B mkdir /tmp/many; cd /tmp/many; i=0; while [ $i -lt 3000 ]; do : > file-with-a-long-name-$i; i=$((i+1)); done
/bin/ls /tmp/many | $B head -1; echo "ls | head -1: pipeline rc=$?"
( /bin/ls -l /tmp/many; echo "ls rc=$?" >&2 ) 2>&1 | $B head -1
/bin/ls -l /tmp/many > /full/out; echo "ls -l > /full/out rc=$? (size $($B stat -c %s /full/out))"
/bin/cat /bin/kcontaineros /bin/kcontaineros > /full/out2; echo "cat > /full/out2 rc=$? (size $($B stat -c %s /full/out2))"
/bin/cp /bin/kcontaineros /full/cp1; echo "cp to full tmpfs rc=$? (size $($B stat -c %s /full/cp1 2>&1))"
