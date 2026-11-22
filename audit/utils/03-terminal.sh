#!/usr/bin/env bash
# (c) Terminal safety. Runs in/term.sh on a pseudo-terminal (test/term.py)
# and reports every case whose output contains a byte that is not printable
# ASCII. The raw capture is out/term.raw.
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$HERE/../.." && pwd)
timeout 200 python3 "$ROOT/test/term.py" -- docker run -it --rm --platform linux/arm64 --pids-limit 256 "$IMG" \
  /bb/busybox sh -c "$(cat "$HERE/in/term.sh")" > "$OUT/term.raw" 2>&1
python3 - "$OUT/term.raw" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
cases = data.split(b'\n### ')
bad = 0
print("cases:", len(cases) - 2)
for c in cases[1:]:
    name, _, body = c.partition(b'\n')
    raw = sorted(set(b for b in body if not (0x20 <= b < 0x7f or b == 0x0a)))
    if raw:
        bad += 1
        print("RAW  %-16s bytes %s   output: %r" % (name.decode(), ' '.join('%02x' % b for b in raw), body[:120]))
    else:
        print("safe %-16s %r" % (name.decode(), body[:100]))
print("cases with raw control bytes:", bad)
PY
