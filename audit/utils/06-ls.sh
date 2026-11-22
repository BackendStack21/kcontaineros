#!/usr/bin/env bash
# (a) ls, ls -a, ls -l, ls -la against what busybox stat says about each entry.
. "$(dirname "$0")/lib.sh"
under_init ls.sh --tmpfs /work:size=16m 2>&1 | tee "$OUT/ls.txt"
