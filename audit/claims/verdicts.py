#!/usr/bin/env python3
"""Verdict per mutant from the suite logs in audit/claims/mutants/.

A failing check counts as a kill only if it is a failure of content: checks
that also fail in a run of the unmodified sources (m0, m0b, m0c) are set
aside, and so are failures where expected and actual hold the same lines in
another order (stdout and stderr of `docker run` racing each other), and
the checks in RACY, measured to fail on the unmodified image as well.
"""
import glob, os, re, sys

# `sh -c 'sleep 1 & grep SigIgn /proc/$!/status'` run 40 times on the unmodified image gave
# SigIgn 0 once (the child is read before it has set its dispositions); 3 of 40 on mutant m1.
RACY = {"background commands ignore SIGINT and SIGQUIT"}
d = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mutants")

def failures(log):
    out, cur = {}, None
    for line in open(log, errors="replace"):
        m = re.match(r"  FAIL  (.*)", line)
        if m:
            cur = m.group(1).rstrip("\n"); out[cur] = ([], [])
        elif cur and line.startswith("        expected | "): out[cur][0].append(line[19:])
        elif cur and line.startswith("        actual   | "): out[cur][1].append(line[19:])
        elif not line.startswith("        "): cur = None
    return out

def num(n): return (int(re.sub(r"\D", "", n) or 0), n)
logs = {os.path.basename(p)[:-4]: p for p in glob.glob(os.path.join(d, "m*.log")) if "-run" not in p}
base = set()
for n in logs:
    if n.startswith("m0"): base |= set(failures(logs[n]))
for n in sorted(logs, key=num):
    f = failures(logs[n])
    tally = [l.strip() for l in open(logs[n], errors="replace") if l.startswith("passed: ")]
    order = [c for c, (e, a) in f.items() if sorted(e) == sorted(a)]
    real = [c for c in f if c not in order and c not in base and c not in RACY]
    kind = "baseline" if n.startswith("m0") else ("KILLED" if real else "SURVIVED")
    print("%-4s %-9s %s" % (n, kind, tally[-1] if tally else "suite did not finish"))
    for c in real: print("       killed by: " + c)
    for c in f:
        if c not in real: print("       set aside (%s): %s" % ("order of lines only" if c in order else "racy, see RACY" if c in RACY else "also fails on unmodified sources", c))
