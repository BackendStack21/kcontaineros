#!/usr/bin/env bash
# (b) Safety of the destructive tools: refusals, limits, error paths, races.
. "$(dirname "$0")/lib.sh"
T=900; DOCKER="timeout $T docker run --rm --platform linux/arm64"
RUN="--tmpfs /work:size=64m --pids-limit 4096 --memory 1g"
under_init safety.sh $RUN > "$OUT/safety.txt" 2>&1
cat "$OUT/safety.txt"
echo; echo "== rm -r against a directory swapped with a symlink to a tree outside the operand"
for impl in k b; do for v in slash relslash plain nested; do
  $DOCKER -i $RUN "$IMG" /bb/busybox sh -s $impl $v ${ROUNDS:-300} < "$HERE/in/race-rm.sh"
done; done 2>&1 | tee "$OUT/race-rm.txt"
echo; echo "== read-only root filesystem, under init (root without capabilities)"
under_init readonly.sh --read-only --tmpfs /tmp 2>&1 | tee "$OUT/readonly-init.txt"
echo; echo "== read-only root filesystem, control without init (root with capabilities)"
control readonly.sh --read-only --tmpfs /tmp 2>&1 | tee "$OUT/readonly-control.txt"
