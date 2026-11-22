#!/usr/bin/env bash
# End-to-end tests for kContainerOS. Needs Docker on an ARM64 host, python3
# and curl.
#
#   test/e2e.sh          build the image and test it
#   IMG=name test/e2e.sh build and test under another image name
#   COV=1 test/e2e.sh    test the instrumented build instead and require
#                        MIN_LINES percent line coverage (default 99)
#
# Every check compares complete output and the exit status, so a command
# that fails cannot pass by printing nothing.
set -u
cd "$(dirname "$0")/.."

PLATFORM=linux/arm64
BUSYBOX='busybox:1.38.0-musl@sha256:80e38f9a1b39188b8bdb28879178edb322a4402b081a9aedda1924609decd6f6'
COV=${COV:-}
MIN_LINES=${MIN_LINES:-99}
ID=$$
TEST=kcos-test-$ID            # the image under test plus a static busybox in /bb
SEALED=kcos-sealed-$ID        # the init-only image, and the same plus busybox
BENCH=kcos-bench-$ID          # long-lived container most checks exec into
VOL=kcos-cov-$ID              # where instrumented processes leave their counters
HTTP=kcos-http-$ID
REPRO=kcos-repro-$ID
pass=0
fail=0

if [ -n "$COV" ]; then IMG=kcontaineros-cov; else IMG=${IMG:-kcontaineros}; fi
D=(--platform "$PLATFORM")
[ -n "$COV" ] && D+=(-v "$VOL:/cov")

cleanup() {
  docker ps -aq --filter "name=^/kcos-.*-$ID\$" | xargs -r docker rm -f >/dev/null 2>&1
  docker rmi -f "$TEST" "$HTTP" "$REPRO" "$SEALED" "$SEALED-test" >/dev/null 2>&1
  [ -n "$COV" ] && docker volume rm -f "$VOL" >/dev/null 2>&1
}
trap cleanup EXIT

ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
ko() {
  fail=$((fail + 1))
  printf '  FAIL  %s\n' "$1"
  printf '%s\n' "$2" | sed 's/^/        expected | /'
  printf '%s\n' "$3" | sed 's/^/        actual   | /'
}
# check NAME EXPECTED ACTUAL
check() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "$2" "$3"; fi; }
# expect NAME RC OUTPUT -- COMMAND...   (stdout and stderr together, stdin empty)
expect() {
  local name=$1 rc=$2 want=$3 out got
  shift 4
  out=$("$@" 2>&1 </dev/null); got=$?
  check "$name" "$want
[rc $rc]" "$out
[rc $got]"
}
# expect_in NAME RC OUTPUT INPUT -- COMMAND...   (INPUT on stdin)
expect_in() {
  local name=$1 rc=$2 want=$3 input=$4 out got
  shift 5
  out=$(printf '%s' "$input" | "$@" 2>&1); got=$?
  check "$name" "$want
[rc $rc]" "$out
[rc $got]"
}
# Commands in the bench container run with stderr joined to stdout inside
# the container, so the two keep their order. MERGE replaces itself with
# the command, adding no process in between.
MERGE=(/bb/busybox sh -c 'exec "$@" 2>&1' merge)
BBPATH=/bb:/usr/local/bin:/usr/bin:/bin:/sbin
# x NAME RC OUTPUT COMMAND...          run a command in the bench container
x() { local n=$1 rc=$2 want=$3; shift 3; expect "$n" "$rc" "$want" -- docker exec "$BENCH" "${MERGE[@]}" "$@"; }
# t NAME RC OUTPUT SCRIPT [ARGS...]    run a snippet with the shell under test
t() { local n=$1 rc=$2 want=$3 script=$4; shift 4; x "$n" "$rc" "$want" sh -c "$script" sh "$@"; }
# tu ...                               the same as the unprivileged user "nobody"
tu() { local n=$1 rc=$2 want=$3 script=$4; shift 4; expect "$n" "$rc" "$want" -- docker exec -u 65534:65534 "$BENCH" "${MERGE[@]}" sh -c "$script" sh "$@"; }
# k NAME RC OUTPUT SCRIPT              a check driven by busybox sh, for when it
#                                      needs $!, $(...) or a loop. Busybox tools
#                                      come first on PATH there, so the tools
#                                      under test are called as /bin/NAME.
k() { local n=$1 rc=$2 want=$3; shift 3; expect "$n" "$rc" "$want" -- docker exec -e "PATH=$BBPATH" "$BENCH" /bb/busybox sh -c "{ $1
} 2>&1"; }
# bb SCRIPT                            set something up with busybox (not under test)
bb() { docker exec -e "PATH=$BBPATH" "$BENCH" /bb/busybox sh -c "$1"; }
# run [DOCKER OPTIONS] -- ARGS...      a throwaway container of the test image
run() {
  local opts=()
  while [ "$1" != -- ]; do opts+=("$1"); shift; done
  shift
  docker run --rm "${D[@]}" ${opts[@]+"${opts[@]}"} "$TEST" "$@"
}
# start [DOCKER OPTIONS] -- ARGS...    a detached container; prints its name
start() {
  local opts=() name
  while [ "$1" != -- ]; do opts+=("$1"); shift; done
  shift
  name=kcos-c$RANDOM$RANDOM-$ID
  docker run -d --name "$name" "${D[@]}" ${opts[@]+"${opts[@]}"} "$TEST" "$@" >/dev/null && echo "$name"
}
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
# typed INPUT... -- COMMAND...         drive a command through a terminal
typed() { python3 test/term.py "$@"; }

# ---------------------------------------------------------------- build
echo "== build ($IMG)"
if [ -n "$COV" ]; then target=(--target cov); else target=(); fi
if ! log=$(docker build --platform "$PLATFORM" ${target[@]+"${target[@]}"} -t "$IMG" . 2>&1); then
  printf '%s\n' "$log" | tail -40; echo "build failed"; exit 1
fi
RUST=$(sed -n 's/^FROM .* \(rust:[^ ]*\) AS toolchain$/\1/p' Dockerfile)
if ! log=$(docker build --platform "$PLATFORM" -t "$TEST" -f - test 2>&1 <<DOCKERFILE
FROM $BUSYBOX AS bb
FROM $RUST AS probe
COPY probe.rs /probe.rs
RUN rustc -O -C panic=abort /probe.rs -o /probe
FROM $IMG
COPY --from=bb /bin/busybox /bb/busybox
COPY --from=probe /probe /bb/probe
# The suite sets things up as root and runs busybox from /bb. The image's
# own defaults (nobody, /bin:/sbin:/usr only) are checked on \$IMG itself.
USER 0
ENV KCOS_EXEC=/bb
RUN ["/bb/busybox", "--install", "-s", "/bb"]
DOCKERFILE
); then printf '%s\n' "$log" | tail -20; echo "test image build failed"; exit 1; fi
if [ -n "$COV" ]; then
  docker volume create "$VOL" >/dev/null
  docker run --rm -v "$VOL:/cov" "$BUSYBOX" chmod 1777 /cov
fi
docker run -d --name "$BENCH" "${D[@]}" "$TEST" /bb/busybox sleep 86400 >/dev/null || exit 1
bb 'mkdir -p /t /cases' && docker cp -q test/cases/. "$BENCH:/cases/" || exit 1

. test/suite.sh

# ------------------------------------------------------------- coverage
if [ -n "$COV" ]; then
  echo "== coverage"
  docker rm -f "$BENCH" >/dev/null 2>&1
  report=$(docker build -q --platform "$PLATFORM" --target covtools . 2>/dev/null) || { echo "covtools build failed"; exit 1; }
  mkdir -p target
  docker run --rm --platform "$PLATFORM" -v "$VOL:/cov" --entrypoint sh "$report" -c '
    set -e
    tools=$(dirname "$(find /usr/local/rustup -name llvm-profdata | head -1)")
    bin=/src/target/aarch64-unknown-linux-musl/debug/kcontaineros
    find /cov -name "*.profraw" > /tmp/list
    echo "profiles: $(wc -l < /tmp/list)"
    "$tools/llvm-profdata" merge -sparse -f /tmp/list -o /tmp/merged.profdata
    "$tools/llvm-cov" report "$bin" -instr-profile=/tmp/merged.profdata --ignore-filename-regex="/rustc/|/usr/local/"
    echo "--- uncovered lines"
    "$tools/llvm-cov" show "$bin" -instr-profile=/tmp/merged.profdata --ignore-filename-regex="/rustc/|/usr/local/" \
      --show-line-counts-or-regions=false | awk "/^\\/src\\//{file=\$0} /^ +[0-9]+\\| +0\\|/{print file \$0}" | sed "s|^/src/||"
  ' | tee target/coverage.txt
  lines=$(awk '$1=="TOTAL"{gsub("%","",$10); print $10}' target/coverage.txt)
  echo
  echo "line coverage: ${lines:-unknown}% (required: $MIN_LINES%)"
  python3 -c "import sys; sys.exit(0 if float('${lines:-0}') >= float('$MIN_LINES') else 1)" || fail=$((fail + 1))
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
