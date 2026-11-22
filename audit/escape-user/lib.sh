# Shared by the harness scripts. Source from the repo root or anywhere.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=kcos-audit-escape-user
IMG=$T-img          # kcos-audit + kp, USER 0 (we pass -u 65534:65534), KCOS_EXEC=/bb
THIRD=$T-third      # FROM kcontaineros + /app/bin, ENV KCOS_EXEC=/app/bin, user nobody
SEALED=$T-sealed    # FROM kcontaineros:sealed + /bb, ENV KCOS_EXEC=/bb, user nobody
NOBODY="-u 65534:65534"
D="timeout 120 docker run --rm --platform linux/arm64"
# with init / the control without it (busybox as the entrypoint)
CTL="--entrypoint /bb/busybox"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  HELD     $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FINDING  $*"; }
note() { echo "  NOTE     $*"; }
# say NAME 'text' : print a captured output, indented
show() { echo "$1" | sed 's/^/    | /'; }
cleanup_names() {
  docker ps -aq --filter "name=$T-" | xargs -r docker rm -f >/dev/null 2>&1
  docker volume ls -q --filter "name=$T-" | xargs -r docker volume rm >/dev/null 2>&1
}
summary() { echo; echo "== $(basename "$0"): $PASS held, $FAIL finding(s)"; }
