# Shared by the harness scripts. Source it from the repo root or anywhere.
# IMG is the prepared audit image: release image + static busybox at /bb,
# USER 0, ENV KCOS_EXEC=/bb.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMG=${IMG:-kcos-audit-utils-img}
OUT=$HERE/out
mkdir -p "$OUT"
DOCKER="timeout ${T:-300} docker run --rm --platform linux/arm64"

# under_init SCRIPT [docker args...]: feed in/SCRIPT to busybox sh running
# under /sbin/init (the lockdown is active, root holds no capability).
under_init() { local s=$1; shift; $DOCKER -i "$@" "$IMG" /bb/busybox sh -s < "$HERE/in/$s"; }
# control SCRIPT [docker args...]: the same without init (root with Docker's capabilities).
control() { local s=$1; shift; $DOCKER -i --entrypoint /bb/busybox "$@" "$IMG" sh -s < "$HERE/in/$s"; }
