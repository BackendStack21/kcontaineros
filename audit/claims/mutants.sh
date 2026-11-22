#!/usr/bin/env bash
# Mutation testing of the lockdown checks. Run from the repo root:
#
#   audit/claims/mutants.sh            every mutant (m0 is the unmodified baseline)
#   audit/claims/mutants.sh m3 m6      only these
#
# For each mutant: copy the repo to a temporary directory outside it, apply
# one change (audit/claims/mutants.py), run the project's own suite on the
# copy with IMG=kcos-audit-claims-mN, keep the log and the diff in
# audit/claims/mutants/, remove the image. One after another, never in
# parallel. Verdicts come from verdicts.py: failures that the unmodified sources
# (m0, m0b, m0c) also show, and failures where only the order of the output
# lines differs, are not kills.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$REPO/audit/claims
OUT=$HERE/mutants
WORK=${TMPDIR:-/tmp}/kcos-audit-claims-mut
mkdir -p "$OUT"
[ $# -gt 0 ] || set -- $(python3 "$HERE/mutants.py" list)
for m in "$@"; do
  rm -rf "$WORK"; mkdir -p "$WORK"
  rsync -a --exclude target --exclude audit --exclude .git --exclude node_modules "$REPO/" "$WORK/"
  python3 "$HERE/mutants.py" apply "$m" "$WORK" > "$OUT/$m.diff" || { echo "$m: cannot apply"; continue; }
  img=kcos-audit-claims-$m
  start=$(date +%s)
  # e2e.sh names what it creates kcos-...-$$; remember that number to clean up after a timeout.
  ( cd "$WORK" && IMG=$img timeout 1500 bash -c 'echo $$ > .suite-pid; exec test/e2e.sh' ) > "$OUT/$m.log" 2>&1
  rc=$?
  id=$(cat "$WORK/.suite-pid" 2>/dev/null)
  if [ -n "$id" ]; then
    docker ps -aq --filter "name=^/kcos-.*-$id\$" | xargs -r docker rm -f >/dev/null 2>&1
    docker rmi -f "kcos-test-$id" "kcos-http-$id" "kcos-repro-$id" "kcos-sealed-$id" "kcos-sealed-$id-test" >/dev/null 2>&1
  fi
  docker rmi -f "$img" >/dev/null 2>&1
  grep -E '^  FAIL  ' "$OUT/$m.log" | sed 's/^  FAIL  //' | LC_ALL=C sort > "$OUT/$m.failed"
  tally=$(grep -E '^passed: ' "$OUT/$m.log" | tail -1)
  echo "$m rc=$rc secs=$(( $(date +%s) - start )) ${tally:-no tally (timeout or build failure)}" | tee -a "$OUT/summary.txt"
done
rm -rf "$WORK"
echo
echo "== verdicts"
python3 "$HERE/verdicts.py" | tee "$OUT/verdicts.txt"
