# Helpers for the claim checks. Sourced by claims.sh; run from the repo root.
#
#   claim ID 'the claim, with its source'      start a claim (README=R, index.html=I, llms.txt=L)
#   t  NAME RC OUTPUT -- COMMAND...            experiment: complete output (stdout+stderr) and status must match
#   tc NAME RC OUTPUT -- COMMAND...            the control for a refusal (same attempt without init)
#   v  NAME EXPECTED ACTUAL                    compare two values measured on the host
#
# The expected value is what the documentation says, not what the image does:
# a line "DIFF" is a claim that did not hold. Results go to out/results.tsv.
set -u
P=(--platform linux/arm64)
IMG=kcontaineros                 # the release image, user nobody
SEALED=kcontaineros:sealed       # init only
A=kcos-audit-claims-img          # release image + /bb/busybox, /bb/probe, /bb/sc; USER 0; KCOS_EXEC=/bb
HERE=audit/claims
OUT=$HERE/out
mkdir -p "$OUT"
RES=$OUT/results.tsv
PRIV=(--privileged --user 0 --security-opt seccomp=unconfined)
NOBODY=(--user 65534:65534)
CUR=""; nclaims=0; ntests=0; ndiff=0
R() { timeout 120 docker run --rm "${P[@]}" "$@"; }
claim() { CUR=$1; nclaims=$((nclaims + 1)); printf '\n[%s] %s\n' "$1" "$2"; printf '%s\tCLAIM\t%s\n' "$1" "$2" >> "$RES"; }
v() {
  ntests=$((ntests + 1))
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; printf '%s\tok\t%s\n' "$CUR" "$1" >> "$RES"
  else ndiff=$((ndiff + 1)); printf '  DIFF  %s\n' "$1"; printf '%s\n' "$2" | sed 's/^/        claimed  | /'; printf '%s\n' "$3" | sed 's/^/        observed | /'
       printf '%s\tDIFF\t%s\n' "$CUR" "$1" >> "$RES"; fi
}
t() {
  local name=$1 rc=$2 want=$3 out got
  shift 4
  out=$("$@" 2>&1 </dev/null); got=$?
  v "$name" "$want
[rc $rc]" "$out
[rc $got]"
}
tc() { local n=$1; shift; t "control: $n" "$@"; }
# under init, as root, with busybox:   bi 'script'      (stderr joined inside the container)
bi() { R "${BIOPT[@]+"${BIOPT[@]}"}" "$A" /bb/busybox sh -c "{ $1
} 2>&1"; }
# the same without init
bc() { R "${BIOPT[@]+"${BIOPT[@]}"}" --entrypoint /bb/busybox "$A" sh -c "{ $1
} 2>&1"; }
# with the shell under test, as the image's default user, stderr joined by the shell itself
si() { R "${BIOPT[@]+"${BIOPT[@]}"}" "$IMG" sh -c "$1"; }
summary() {
  echo
  echo "claims: $nclaims  experiments: $ntests  did not hold: $ndiff"
  echo "claims with at least one DIFF:"
  awk -F'\t' '$2=="DIFF"{print "  " $1 ": " $3}' "$RES"
}
