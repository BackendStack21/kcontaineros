#!/bin/sh
# Build the release image twice from scratch (no cache), sequentially, into
# kcos-audit-supply-a and kcos-audit-supply-b.
# Logs go to audit/supply/out/. Run from the repo root. Takes a few minutes.
# Set SKIP_BUILD=1 to reuse existing tags.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$here/out
mkdir -p "$out"
if [ "${SKIP_BUILD:-}" = 1 ]; then echo "SKIP_BUILD=1: not rebuilding"; exit 0; fi
for t in a b; do
    echo "== building kcos-audit-supply-$t (--no-cache)"
    timeout 900 docker build --no-cache --progress=plain --platform linux/arm64 \
        -t "kcos-audit-supply-$t" "$root" >"$out/build-$t.log" 2>&1
    echo "   exit $?"
done
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}' | grep '^kcos-audit-supply' || true
