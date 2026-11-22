#!/bin/sh
# Structured stress of the kcos shell: very long tokens, deep nesting, huge
# numbers of arguments, redirections, pipes, list elements, assignments,
# continuation lines. Each case is generated inside the container with
# busybox awk, run through /bin/sh with a time limit, and reported as
#   NAME MODE status=N seconds=S maxrss_kb=K input_bytes=B
# status 137 = time limit (LIMIT seconds) or killed for memory.
#   sh audit/shell/stress.sh
IMG=${IMG:-kcos-audit}
LIMIT=${LIMIT:-30}
cat > "${TMPDIR:-/tmp}/kcos-audit-shell-stress-in.sh" <<'INNER'
B=/bb/busybox
gen() { $B awk "BEGIN { $1 }" > /tmp/in.sh; }
rep() { $B awk -v s="$1" -v n="$2" 'BEGIN { for (i = 0; i < n; i++) printf "%s", s }'; }
run() { # name mode
  size=$($B wc -c < /tmp/in.sh)
  case $2 in
    file)  $B time -v $B timeout -s KILL $LIMIT /bin/sh /tmp/in.sh >/dev/null 2>/tmp/err </dev/null;;
    stdin) $B time -v $B timeout -s KILL $LIMIT /bin/sh </tmp/in.sh >/dev/null 2>/tmp/err;;
  esac
  st=$($B sed -n 's/.*Exit status: //p' /tmp/err); sig=$($B sed -n 's/.*terminated by signal //p' /tmp/err)
  el=$($B sed -n 's/.*Elapsed (wall clock) time (h:mm:ss or m:ss): //p' /tmp/err)
  rss=$($B sed -n 's/.*Maximum resident set size (kbytes): //p' /tmp/err)
  echo "$1 $2 status=${st:-sig$sig} seconds=$el maxrss_kb=$rss input_bytes=$size first_stderr=$($B head -c 60 /tmp/err | $B tr '\n' ' ')"
  kill -9 -1 2>/dev/null
}
both() { run $1 file; run $1 stdin; }
cd /tmp
{ printf ': '; rep a 1000000; echo; } > /tmp/in.sh; both token-1MB
{ printf ': '; rep aaaaaaaaaaaaaaaa 4000000; echo; } > /tmp/in.sh; both token-64MB
{ printf ": '"; rep aaaaaaaaaaaaaaaa 1000000; echo "'"; } > /tmp/in.sh; both squote-16MB
{ printf ': "'; rep aaaaaaaaaaaaaaaa 1000000; echo '"'; } > /tmp/in.sh; both dquote-16MB
{ printf ': "'; rep '$A' 1000000; echo '"'; } > /tmp/in.sh; both dquote-1M-expansions
{ printf ': '; rep 'a ' 1000000; echo; } > /tmp/in.sh; both args-1M-builtin
{ printf '/bin/true '; rep 'a ' 1000000; echo; echo :; } > /tmp/in.sh; both args-1M-external
{ printf 'set -- '; rep 'a ' 100000; echo; printf ': '; rep '"$@" ' 100; echo; } > /tmp/in.sh; both at-100k-x100
{ printf ': '; rep '${A:-' 32; rep '}' 32; echo; } > /tmp/in.sh; both nest-32
{ printf ': '; rep '${A:-' 33; rep '}' 33; echo; } > /tmp/in.sh; both nest-33
{ printf ': '; rep '${A:-' 200000; rep '}' 200000; echo; } > /tmp/in.sh; both nest-200k
{ printf ': '; rep '${A:-' 200000; echo; } > /tmp/in.sh; both nest-200k-open
{ printf ': '; rep '${A:-x}' 200000; echo; } > /tmp/in.sh; both defaults-200k
{ printf ': '; rep '>/dev/null ' 100000; echo; } > /tmp/in.sh; both redirs-100k-builtin
{ printf '/bin/true '; rep '>/dev/null ' 100000; echo; echo :; } > /tmp/in.sh; both redirs-100k-external
{ printf ': '; rep '3>&1 ' 100000; echo; } > /tmp/in.sh; both dups-100k-builtin
{ rep ': | ' 3000; echo :; } > /tmp/in.sh; both pipes-3000
{ rep 'true | ' 3000; echo true; } > /tmp/in.sh; both pipes-3000-external
{ rep ': && ' 300000; echo :; } > /tmp/in.sh; both and-300k
{ rep 'false || ' 20000; echo :; } > /tmp/in.sh; both or-20k-external
{ rep ': ; ' 300000; echo :; } > /tmp/in.sh; both seq-300k
{ rep ': && ' 100000; echo ': &'; echo wait; } > /tmp/in.sh; both and-100k-background
rep ':
' 500000 > /tmp/in.sh; both lines-500k
rep '
' 5000000 > /tmp/in.sh; both newlines-5M
{ rep ';' 1000000; echo; } > /tmp/in.sh; both semicolons-1M
{ printf '#'; rep x 16000000; echo; } > /tmp/in.sh; both comment-16MB
{ rep ': &
' 3000; echo wait; } > /tmp/in.sh; both background-3000
{ rep '/bin/true &
' 3000; echo wait; } > /tmp/in.sh; both background-3000-external
{ rep 'A=1 ' 3000; echo :; } > /tmp/in.sh; both assigns-3000-one-command
{ rep 'A=1 ' 10000; echo :; } > /tmp/in.sh; both assigns-10000-one-command
$B awk 'BEGIN { for (i = 0; i < 20000; i++) printf "V%d=%d\n", i, i }' > /tmp/in.sh; both vars-20000
{ printf ': '; $B yes 'a \' | $B head -n 3000; echo; } > /tmp/in.sh; both continuation-3000-lines
{ echo 'true &&'; rep '
' 20000; echo :; } > /tmp/in.sh; both andand-then-20000-blank-lines
{ printf ': '; $B yes '\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\' | $B head -n 100000 | $B tr -d '\n'; echo; } > /tmp/in.sh; both backslashes-6MB
{ printf 'exit '; rep 9 1000000; echo; } > /tmp/in.sh; both exit-1M-digits
{ printf ': '; rep 9 1000000; echo '>/dev/null'; } > /tmp/in.sh; both fd-1M-digits
{ printf ': ${'; rep 9 1000000; echo '}'; } > /tmp/in.sh; both param-1M-digits
{ printf 'shift '; rep 9 100000; echo; } > /tmp/in.sh; both shift-100k-digits
{ printf ': '; rep '"' 1000001; echo; } > /tmp/in.sh; both dquotes-odd-1M
{ printf 'X='; rep a 20000000; echo; echo ': $X$X$X$X'; } > /tmp/in.sh; both value-20MB-x4
echo DONE
INNER
timeout 3000 docker run --rm --platform linux/arm64 --name kcos-audit-shell-stress-$$ \
  --memory 1g --memory-swap 1g --pids-limit 256 -e LIMIT=$LIMIT \
  -v "${TMPDIR:-/tmp}/kcos-audit-shell-stress-in.sh:/in.sh:ro" --entrypoint /bb/busybox "$IMG" sh /in.sh
rm -f "${TMPDIR:-/tmp}/kcos-audit-shell-stress-in.sh"
