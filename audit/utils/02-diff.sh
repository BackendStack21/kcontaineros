#!/usr/bin/env bash
# (a) Differential against busybox on a generated corpus, under init and in
# the control without init (root with Docker's capabilities). Prints the
# cases that differ; complete logs are out/diff-init.tsv and out/diff-control.tsv.
. "$(dirname "$0")/lib.sh"
T=900
DOCKER="timeout $T docker run --rm --platform linux/arm64"
$DOCKER -i --tmpfs /work:size=48m --pids-limit 8192 --memory 768m "$IMG" /bb/busybox sh -s init < "$HERE/in/diff.sh" > "$OUT/diff-init.tsv" 2> "$OUT/diff-init.err"
$DOCKER -i --entrypoint /bb/busybox --tmpfs /work:size=48m --pids-limit 8192 --memory 768m "$IMG" sh -s control < "$HERE/in/diff.sh" > "$OUT/diff-control.tsv" 2> "$OUT/diff-control.err"
for m in init control; do
  echo "===== $m: $(tail -1 "$OUT/diff-$m.tsv")"
  grep -v '^SAME' "$OUT/diff-$m.tsv" | grep -v '^TOTAL'
  [ -s "$OUT/diff-$m.err" ] && { echo "--- harness stderr (first 10 lines):"; head -10 "$OUT/diff-$m.err"; }
done
exit 0
