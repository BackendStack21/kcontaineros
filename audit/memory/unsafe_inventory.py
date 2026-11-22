#!/usr/bin/env python3
"""List every unsafe item in src/ (track: memory, part a).

usage: python3 audit/memory/unsafe_inventory.py      (from the repo root)

Counts, per file: `unsafe fn`, `unsafe impl`, `unsafe { }` blocks,
asm!/global_asm!, `extern` blocks and ABI functions, `static mut`, and the
safe functions in sys.rs that take a raw pointer (their callers carry an
obligation the type system does not show). Comment lines are skipped.
"""
import glob
import re

KINDS = [
    ("unsafe fn", r"\bunsafe\s+(extern\s+\"C\"\s+)?fn\b"),
    ("unsafe impl", r"\bunsafe\s+impl\b"),
    ("unsafe block", r"\bunsafe\s*\{"),
    ("asm", r"\b(global_asm|asm)!\s*\("),
    ("extern item", r"\bextern\s+\"C\""),
    ("static mut", r"\bstatic\s+mut\b"),
    ("from_raw_parts", r"from_raw_parts"),
    ("no_mangle", r"#\[no_mangle\]"),
]
total = {k: 0 for k, _ in KINDS}
for path in sorted(glob.glob("src/*.rs")):
    rows = []
    cov = False
    for no, line in enumerate(open(path), 1):
        code = line.split("//")[0]
        if not code.strip():
            continue
        for kind, rx in KINDS:
            if re.search(rx, code):
                rows.append((no, kind, line.strip()[:100]))
                total[kind] += 1
    print("%s: %d" % (path, len(rows)))
    if path.endswith("sys.rs"):
        blocks = [r for r in rows if r[1] == "unsafe block"]
        other = [r for r in rows if r[1] != "unsafe block"]
        print("    %d unsafe blocks, each one call of sc() (lines %d-%d)" % (len(blocks), blocks[0][0], blocks[-1][0]))
        rows = other
    for no, kind, text in rows:
        print("    %4d  %-14s %s" % (no, kind, text))
print("\ntotals: " + ", ".join("%s %d" % kv for kv in total.items()))

# safe wrappers with a pointer contract
src = open("src/sys.rs").read()
safe_ptr = re.findall(r"^pub fn (\w+)\(([^)]*\*const[^)]*)\)", src, re.M)
print("\nsafe functions in sys.rs that take a raw pointer (%d): the caller must pass a NUL-terminated string\n"
      "or a NULL-terminated pointer array that outlives the call, and nothing checks it:" % len(safe_ptr))
for name, args in safe_ptr:
    print("    %s(%s)" % (name, args))
calls = 0
for path in sorted(glob.glob("src/*.rs")):
    if path.endswith("sys.rs"):
        continue
    for no, line in enumerate(open(path), 1):
        if re.search(r"sys::(%s)\(" % "|".join(n for n, _ in safe_ptr), line):
            calls += 1
print("call sites of those functions outside sys.rs: %d (each read for this audit; see REPORT.md)" % calls)
