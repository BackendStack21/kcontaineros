#!/bin/sh
# Allocator stress test (track: memory, part c). From the repo root:
#   sh audit/memory/run_alloc.sh
# Cuts the allocator out of src/main.rs, builds it with the real src/sys.rs
# and src/util.rs into a std test program inside rust:1-alpine (no network,
# no cargo, no crates) and runs it there. Nothing is written to the repo.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
timeout 900 docker run --rm --platform linux/arm64 --name kcos-audit-memory-alloc \
  --memory 2g --pids-limit 256 \
  -v "$repo/src:/src:ro" -v "$here/alloc:/harness:ro" rust:1-alpine sh -c '
set -e
mkdir /work
# from "struct Heap;" up to (not including) "#[global_allocator]"
awk "/^struct Heap;/{on=1} /^#\[global_allocator\]/{on=0} on" /src/main.rs > /work/heap.rs
echo "allocator source: $(wc -l < /work/heap.rs) lines cut from src/main.rs"
grep -c "unsafe impl GlobalAlloc for Heap" /work/heap.rs >/dev/null
rustc --edition 2021 -O -A warnings -o /work/stress /harness/stress.rs
echo "--- 1. alignments up to 4096, sizes 1 byte to 1 MiB (errors=0 expected)"
/work/stress 300000 12 1
/work/stress 300000 12 2
echo "--- 2. alignments up to 64 KiB, sizes up to 64 KiB: the size classes (errors=0 expected)"
/work/stress 300000 16 3 small
echo "--- 3. alignments above 4096 with sizes above 64 KiB (nothing in the binary asks for these)"
/work/stress 100000 16 4 || echo "(exit status $?)"
echo "--- 4. debug build, overflow checks on, as 1. (errors=0 and no panic expected)"
rustc --edition 2021 -C debug-assertions=on -C overflow-checks=on -A warnings -o /work/stress-dbg /harness/stress.rs
/work/stress-dbg 100000 12 5
'
