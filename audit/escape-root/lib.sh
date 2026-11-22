# Sourced by the harness scripts of the escape-root track.
# Requires the images kcos-audit (see the audit brief) and kcos-audit-escape-root-img (build.sh).
IMG=${IMG:-kcos-audit-escape-root-img}
PLAT="--platform linux/arm64"
# The configuration the README claims to hold against.
PRIV="--privileged --security-opt seccomp=unconfined --security-opt apparmor=unconfined"
BB=/bb/busybox

# init ARGS...     run a command as root under init, privileged
init() { timeout 120 docker run --rm $PLAT $PRIV "$IMG" "$@" 2>&1; }
# ctl ARGS...      the control: the same command with no init in front
ctl() { timeout 120 docker run --rm $PLAT $PRIV --entrypoint "$1" "$IMG" "${@:2}" 2>&1; }
# section TITLE
section() { printf '\n=== %s ===\n' "$*"; }
