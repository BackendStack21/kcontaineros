#!/usr/bin/env bash
# For the mutants the suite did not catch: show that the change is not an
# equivalent one, by building the mutant and doing what it lets through.
# From the repo root, after audit/claims/build.sh:
#
#   audit/claims/mutant-effect.sh            all of them
#   audit/claims/mutant-effect.sh m6         one
#
# Each mutant image is kcos-audit-claims-eN (the mutated build plus /bb from the
# helper image) and is removed afterwards. "orig" lines are the same attempt on
# the unmodified image, kcos-audit-claims-img.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$REPO/audit/claims
WORK=${TMPDIR:-/tmp}/kcos-audit-claims-eff
P=(--platform linux/arm64)
PRIV=(--privileged --user 0 --security-opt seccomp=unconfined)
attempt() { # NAME DOCKER-OPTIONS... -- SCRIPT
  local opts=(); while [ "$1" != -- ]; do opts+=("$1"); shift; done; shift
  echo "    mutant: $(timeout 120 docker run --rm "${P[@]}" "${opts[@]}" "$IMGX" /bb/busybox sh -c "$1" 2>&1 | tr '\n' ';')"
  echo "    orig:   $(timeout 120 docker run --rm "${P[@]}" "${opts[@]}" kcos-audit-claims-img /bb/busybox sh -c "$1" 2>&1 | tr '\n' ';')"
}
[ $# -gt 0 ] || set -- m1 m3 m6 m7 m8 m11 m12 m13
for m in "$@"; do
  rm -rf "$WORK"; mkdir -p "$WORK"
  rsync -a --exclude target --exclude audit --exclude .git "$REPO/" "$WORK/"
  python3 "$HERE/mutants.py" apply "$m" "$WORK" >/dev/null || continue
  n=${m#m}; IMGX=kcos-audit-claims-e$n
  timeout 900 docker build -q "${P[@]}" -t "$IMGX-base" "$WORK" >/dev/null 2>&1 || { echo "$m: build failed"; continue; }
  printf 'FROM %s\nCOPY --from=kcos-audit-claims-img /bb /bb\nUSER 0\nENV KCOS_EXEC=/bb\n' "$IMGX-base" | timeout 300 docker build -q "${P[@]}" -t "$IMGX" - >/dev/null 2>&1
  echo "== $m: $(head -c 300 "$HERE/mutants/$m.diff" | grep -E '^[-+][^-+]' | tr '\n' ' ' | cut -c1-150)"
  case $m in
    m1) attempt "${PRIV[@]}" -- '/bb/sc 271 999999 0 0 0 0 0' ;;                       # process_vm_writev on a PID that does not exist
    m3) attempt "${PRIV[@]}" -- '(true >> /sys/kernel/mm/transparent_hugepage/enabled) 2>/dev/null; echo "append-open of a /sys file: $?"' ;;
    m6) attempt --user 0 -- '/bb/busybox chmod 666 /bb/probe; /bb/sc 45 s:/bb/probe 0; /bb/busybox wc -c < /bb/probe' ;;   # truncate(2)
    m7) attempt --user 0 --tmpfs /dev/shm:exec -- '/bb/busybox cp /bb/sc /dev/shm/prog; /dev/shm/prog 2>&1' ;;
    m8) attempt --user 0 -- '/bb/busybox chmod 777 /bb; /bb/busybox rm /bb/probe 2>&1; [ -e /bb/probe ] && echo "still there" || echo "removed"' ;;
    m11) attempt --user 0 -e KCOS_DEV=/dev/stdin -- 'echo started' ;;                   # /dev/stdin is a symbolic link
    m12) attempt "${PRIV[@]}" --cap-add ALL -- 'echo "clone(CLONE_NEWNET): $(/bb/sc clone 0x40000000)"; echo "clone(CLONE_NEWNS): $(/bb/sc clone 0x20000)"' ;;
    m13) attempt "${PRIV[@]}" -- 'echo "mount: $(/bb/sc 40 0 0 0 0 0)"; echo "chroot: $(/bb/sc 51 0)"; echo "sethostname: $(/bb/sc 161 0 100000)"; echo "clock_settime: $(/bb/sc 112 0 0)"' ;;
  esac
  docker rmi -f "$IMGX" "$IMGX-base" >/dev/null 2>&1
done
rm -rf "$WORK"
