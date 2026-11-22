# Sourced by the harness scripts. Run them from the repo root after build.sh.
IMG=${IMG:-kcos-audit-init-img}
P="--platform linux/arm64"
pass=0; fail=0
# ok NAME EXPECTED ACTUAL
ok() {
    if [ "$2" = "$3" ]; then pass=$((pass+1)); [ -n "${VERBOSE:-}" ] && echo "ok   $1"
    else fail=$((fail+1)); echo "DIFF $1"; echo "  expected: $(printf %q "$2")"; echo "  actual:   $(printf %q "$3")"; fi
    return 0
}
# r ARGS...: docker run under init, output and "[N]" exit status
r() { local o; o=$(timeout 120 docker run --rm $P "$@" 2>&1); echo "$o[$?]"; }
summary() { echo "== $0: $pass as expected, $fail different"; }
