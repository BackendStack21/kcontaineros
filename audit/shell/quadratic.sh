#!/bin/sh
# Time the stdin reader on inputs where a command is left open across many
# lines (kcos re-checks everything read so far for every further line), and
# the parser on one command with many assignment prefixes.
#   sh audit/shell/quadratic.sh
# Prints NAME N MODE status seconds. busybox sh is timed on the same input.
IMG=${IMG:-kcos-audit}
cat > "${TMPDIR:-/tmp}/kcos-audit-shell-quad-in.sh" <<'INNER'
B=/bb/busybox
t() { # name n
  for sh in "/bin/sh" "$B sh"; do for mode in stdin file; do
    case $mode in
      stdin) $B time -f %e $B timeout -s KILL 60 $sh </tmp/in.sh >/dev/null 2>/tmp/time; r=$?;;
      file)  $B time -f %e $B timeout -s KILL 60 $sh /tmp/in.sh >/dev/null 2>/tmp/time </dev/null; r=$?;;
    esac
    echo "$1 n=$2 shell=${sh##*/} $mode status=$r seconds=$($B tail -n 1 /tmp/time) bytes=$($B wc -c </tmp/in.sh)"
  done; done
}
for n in 5000 10000 20000 40000; do
  { echo 'true &&'; $B yes '' | $B head -n $n; echo :; } >/tmp/in.sh; t andand-blank-lines $n
done
for n in 5000 10000 20000 40000; do
  { echo 'true |'; $B yes '# comment' | $B head -n $n; echo :; } >/tmp/in.sh; t pipe-comment-lines $n
done
for n in 5000 10000 20000 40000; do
  { printf ': '; $B yes 'a \' | $B head -n $n; echo; } >/tmp/in.sh; t continuation-lines $n
done
for n in 5000 10000 20000; do
  { printf ": '"; $B yes "''" | $B head -n $n; echo "'"; } >/tmp/in.sh; t quote-reopened-lines $n
done
for n in 5000 10000 20000 40000; do
  { $B yes 'A=1' | $B head -n $n | $B tr '\n' ' '; echo :; } >/tmp/in.sh; t assignment-prefixes $n
done
INNER
timeout 3000 docker run --rm --platform linux/arm64 --name kcos-audit-shell-quad-$$ --memory 512m --pids-limit 64 \
  -v "${TMPDIR:-/tmp}/kcos-audit-shell-quad-in.sh:/in.sh:ro" --entrypoint /bb/busybox "$IMG" sh /in.sh
rm -f "${TMPDIR:-/tmp}/kcos-audit-shell-quad-in.sh"
