#!/usr/bin/env python3
"""Differential test of the kcos shell against busybox sh.

    python3 audit/shell/diff.py [--seed N] [--count N] [--jobs N] [--show N]

Generates COUNT scripts (gen.py), runs each through /bin/sh (kcos) and
/bb/busybox sh in the same container, in three modes (script file, -c
string, stdin), and compares stdout, the files left behind, the exit
status and whether anything was written to stderr.

Every script lands in one class per mode:
  same        identical
  refused     kcos: "sh: syntax error", status 2, no output, no files
  partial     stdin mode only: kcos stopped at a syntax error part-way
  loud        different, and kcos wrote to stderr (an error was reported)
  SILENT      different, and kcos wrote nothing to stderr
Results are written to audit/shell/work/diff-SEED.json.
"""
import argparse, io, json, os, re, subprocess, sys, tarfile, shutil
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.environ.get("IMG", "kcos-audit")
ERR = re.compile(rb"^(\./[^:\n]*:)?(sh: |/w/s/\d+\.sh: |-c: ).*$", re.M)


STDIN_SKIP = re.compile(r"sh -c 'cat' |cat in1 -|exec [^\n]*<")


def norm(b):
    """Error messages that were redirected into stdout or a file."""
    return ERR.sub(lambda m: (m.group(1) or b"") + b"<ERR>", b)


def run_shard(args):
    idx, names, work, modes, limit = args
    d = os.path.join(work, "shard%d" % idx)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "s"))
    for n in names:
        shutil.copy(os.path.join(work, "all", n), os.path.join(d, "s", n))
    shutil.copy(os.path.join(HERE, "inrun.sh"), os.path.join(d, "inrun.sh"))
    cmd = ["timeout", "1500", "docker", "run", "--rm", "--platform", "linux/arm64",
           "--name", "kcos-audit-shell-diff-%d-%d" % (os.getpid(), idx),
           "--memory", "512m", "--pids-limit", "256",
           "-e", "MODES=" + modes, "-e", "LIMIT=%d" % limit,
           "-v", d + ":/w:ro", "--entrypoint", "/bb/busybox", IMG, "sh", "/w/inrun.sh"]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        sys.stderr.write("shard %d: docker exited %d: %s\n" % (idx, p.returncode, p.stderr[-500:].decode("latin1")))
    res = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(p.stdout)) as t:
            for m in t:
                if m.isfile():
                    res[m.name.lstrip("./")] = t.extractfile(m).read()
    except tarfile.TarError as e:
        sys.stderr.write("shard %d: bad tar: %s\n" % (idx, e))
    shutil.rmtree(d, ignore_errors=True)
    return res


def run_scripts(scripts, work, jobs=4, modes="file c stdin", limit=10):
    """scripts: list of bytes. Returns {(index, shell, mode): (out, err, rc, files)}"""
    alld = os.path.join(work, "all")
    shutil.rmtree(alld, ignore_errors=True)
    os.makedirs(alld)
    names = []
    for i, s in enumerate(scripts):
        n = "%05d.sh" % i
        with open(os.path.join(alld, n), "wb") as f:
            f.write(s)
        names.append(n)
    shards = [(k, names[k::jobs], work, modes, limit) for k in range(jobs) if names[k::jobs]]
    raw = {}
    with ThreadPoolExecutor(jobs) as ex:
        for r in ex.map(run_shard, shards):
            raw.update(r)
    out = {}
    for i in range(len(scripts)):
        for sh in "kb":
            for mode in modes.split():
                base = "%05d.%s.%s" % (i, sh, mode)
                if base + ".r" not in raw:
                    continue
                rc = int(raw[base + ".r"].strip() or b"-1")
                out[(i, sh, mode)] = (raw.get(base + ".o", b""), raw.get(base + ".e", b""), rc, raw.get(base + ".f", b""))
    shutil.rmtree(alld, ignore_errors=True)
    return out


def classify(k, b, mode):
    ko, ke, kr, kf = k
    bo, be, br, bf = b
    if 129 <= kr <= 192 and kr != br:
        return "SIGNAL"
    # the file dump is sorted by line: sort again once the messages are masked
    kf, bf = b"\n".join(sorted(norm(kf).split(b"\n"))), b"\n".join(sorted(norm(bf).split(b"\n")))
    if norm(ko) == norm(bo) and norm(kf) == norm(bf) and kr == br and bool(ke) == bool(be):
        return "same"
    syntax = b"sh: syntax error" in ke
    if syntax and kr == 2 and not ko and not kf:
        return "refused"
    if syntax and mode == "stdin" and kr == 2:
        return "partial"
    if syntax:
        return "SYNTAX-AFTER-RUN"
    if norm(ko) == norm(bo) and norm(kf) == norm(bf) and kr == br:
        return "stderr-only"
    # the same output, both failed and both said so: only the number differs
    if norm(ko) == norm(bo) and norm(kf) == norm(bf) and kr and br and ke and be:
        return "errstatus"
    # more error lines from kcos than from busybox: it reported something
    if ke.count(b"\n") > be.count(b"\n"):
        return "loud"
    return "SILENT"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=3000)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--show", type=int, default=5, help="examples printed per class")
    ap.add_argument("--classes", default="SILENT,SIGNAL,SYNTAX-AFTER-RUN")
    a = ap.parse_args()
    work = os.path.join(HERE, "work")
    os.makedirs(work, exist_ok=True)
    gens = gen.generate(a.seed, a.count)
    res = run_scripts([g[1].encode() for g in gens], work, a.jobs)
    counts, examples, records = {}, {}, []
    for i, (kind, src, tags) in enumerate(gens):
        for mode in ("file", "c", "stdin"):
            k, b = res.get((i, "k", mode)), res.get((i, "b", mode))
            if k is None or b is None:
                cls = "MISSING"
            else:
                cls = classify(k, b, mode)
            # On stdin the two shells read the script differently when a
            # command reads stdin too (busybox reads ahead, kcos a byte at a
            # time), and busybox has `s' in $-: not comparable.
            if mode == "stdin" and cls not in ("same", "refused", "partial") and STDIN_SKIP.search(src):
                cls = "stdin-n/a"
            key = (kind, mode, cls)
            counts[key] = counts.get(key, 0) + 1
            examples.setdefault((kind, cls), []).append((i, mode))
            if cls != "same":
                records.append({"i": i, "kind": kind, "mode": mode, "class": cls, "src": src,
                                "k": [x[:4000].decode("latin1") if isinstance(x, bytes) else x for x in (k or ())],
                                "b": [x[:4000].decode("latin1") if isinstance(x, bytes) else x for x in (b or ())]})
    print("scripts: %d (seed %d), runs per shell: %d" % (len(gens), a.seed, len(gens) * 3))
    for key in sorted(counts):
        print("  %-8s %-6s %-18s %d" % (key + (counts[key],)))
    with open(os.path.join(work, "diff-%d.json" % a.seed), "w") as f:
        json.dump(records, f, indent=1)
    want = a.classes.split(",")
    for (kind, cls), ex in sorted(examples.items()):
        if cls not in want:
            continue
        for i, mode in ex[:a.show]:
            k, b = res[(i, "k", mode)], res[(i, "b", mode)]
            print("\n==== #%d %s %s %s" % (i, kind, mode, cls))
            print(gens[i][1])
            print("-- kcos rc=%d out=%r err=%r files=%r" % (k[2], k[0][:300], k[1][:300], k[3][:300]))
            print("-- bbox rc=%d out=%r err=%r files=%r" % (b[2], b[0][:300], b[1][:300], b[3][:300]))


if __name__ == "__main__":
    main()
