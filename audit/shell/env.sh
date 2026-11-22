#!/bin/sh
# How the shell treats an environment with duplicate names, entries without
# '=', odd names and a 120 kB value. Builds a static helper (envx.c) in an
# alpine container and runs it in kcos-audit without init; busybox sh is
# given the same environment for comparison.
#   sh audit/shell/env.sh
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=${IMG:-kcos-audit}
mkdir -p "$HERE/work"
timeout 300 docker run --rm --platform linux/arm64 --name kcos-audit-shell-cc-$$ -v "$HERE/envx.c:/envx.c:ro" alpine \
  sh -c 'apk add --no-cache gcc musl-dev >/dev/null 2>&1 && gcc -static -O1 -o /envx /envx.c && cat /envx' > "$HERE/work/envx" || exit 1
chmod +x "$HERE/work/envx"
cat > "$HERE/work/env-in.sh" <<'INNER'
B=/bb/busybox
t() {
  echo "== $1"
  echo "-- kcos";    /w/envx "$1" /bin/sh 2>&1 | $B cut -c1-100
  echo "-- busybox"; /w/envx "$1" /bb/busybox 2>&1 | $B cut -c1-100
}
t 'echo "A=$A PWD=$PWD IFS=[$IFS] D=$D"'
t '/bb/busybox env | /bb/busybox sort'
t 'A=third; /bb/busybox env | /bb/busybox grep "^A="'
t 'unset A; /bb/busybox env | /bb/busybox grep -c "^A="'
t 'export NOEQ=5; /bb/busybox env | /bb/busybox grep NOEQ'
t 'unset NOEQ; /bb/busybox env | /bb/busybox grep -c NOEQ'
t 'PATH=/bb; busybox env | busybox grep "^PATH="'
t 'X="a:b c"; /bb/busybox printf "<%s>\n" $X'
t 'cd -'
t '/bb/busybox printf "%s\n" "${#BIG}" 2>&1; echo ${BIG} | /bb/busybox wc -c'
INNER
timeout 120 docker run --rm --platform linux/arm64 --name kcos-audit-shell-env-$$ -v "$HERE/work:/w:ro" \
  --entrypoint /bb/busybox "$IMG" sh /w/env-in.sh
rm -f "$HERE/work/env-in.sh"
