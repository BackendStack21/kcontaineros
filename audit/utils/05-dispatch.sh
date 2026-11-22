#!/usr/bin/env bash
# (e) argv[0] dispatch, the multi-call forms, and --list/--help/--version
# and the utilities when their output cannot be written.
. "$(dirname "$0")/lib.sh"
under_init dispatch.sh --tmpfs /full:size=64k --pids-limit 1024 --memory 512m 2>&1 | tee "$OUT/dispatch.txt"
