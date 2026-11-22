#!/usr/bin/env python3
"""Shrink the scripts that diff.py classed as different.

    python3 audit/shell/reduce.py SEED [CLASS,...] [MODE] [KIND,...]

Reads work/diff-SEED.json, and for each script of the given classes
(default SILENT) repeatedly deletes lines, then list elements, then words,
keeping a deletion when the script still lands in the same class. Prints
the reduced scripts, grouped when several reduce to the same text.
"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import diff

HERE = os.path.dirname(os.path.abspath(__file__))
SPLITS = [r"(\n)", r"(\s*(?:\|\||&&|\||;)\s*)", r"( +)"]


def chunks(src, pattern):
    parts = re.split(pattern, src)
    # [text, sep, text, sep, ...] -> list of (text, sep)
    return [(parts[i], parts[i + 1] if i + 1 < len(parts) else "") for i in range(0, len(parts), 2)]


def main():
    seed = sys.argv[1]
    classes = (sys.argv[2] if len(sys.argv) > 2 else "SILENT").split(",")
    mode = sys.argv[3] if len(sys.argv) > 3 else "file"
    work = os.path.join(HERE, "work")
    kinds = (sys.argv[4] if len(sys.argv) > 4 else "pure,runtime,unsup").split(",")
    recs = [r for r in json.load(open(os.path.join(work, "diff-%s.json" % seed)))
            if r["class"] in classes and r["mode"] == mode and r["kind"] in kinds]
    cur = {r["i"]: r["src"] for r in recs}
    cls = {r["i"]: r["class"] for r in recs}
    for pattern in SPLITS:
        while True:
            cands = []  # (script id, candidate source)
            for i, src in cur.items():
                ch = chunks(src, pattern)
                for k in range(len(ch)):
                    c = "".join(t + s for j, (t, s) in enumerate(ch) if j != k)
                    if c != src and c.strip():
                        cands.append((i, c))
            if not cands:
                break
            res = diff.run_scripts([c.encode() for _, c in cands], work, 4, mode, 5)
            changed = False
            done = set()
            for n, (i, c) in enumerate(cands):
                if i in done:
                    continue
                k, b = res.get((n, "k", mode)), res.get((n, "b", mode))
                if k and b and diff.classify(k, b, mode) == cls[i]:
                    cur[i] = c
                    done.add(i)
                    changed = True
            if not changed:
                break
    final = list(cur.items())
    res = diff.run_scripts([c.encode() for _, c in final], work, 4, mode, 5)
    groups = {}
    for n, (i, c) in enumerate(final):
        groups.setdefault(c, []).append((i, res.get((n, "k", mode)), res.get((n, "b", mode))))
    json.dump([{"src": c, "ids": [g[0] for g in gs]} for c, gs in groups.items()],
              open(os.path.join(work, "reduced-%s-%s.json" % (seed, mode)), "w"), indent=1)
    for c, gs in sorted(groups.items(), key=lambda x: -len(x[1])):
        i, k, b = gs[0]
        print("==== %d script(s), e.g. #%d [%s]" % (len(gs), i, cls[i]))
        print(c)
        if k and b:
            print("-- kcos rc=%d out=%r err=%r files=%r" % (k[2], k[0][:200], k[1][:200], k[3][:200]))
            print("-- bbox rc=%d out=%r err=%r files=%r" % (b[2], b[0][:200], b[1][:200], b[3][:200]))


if __name__ == "__main__":
    main()
