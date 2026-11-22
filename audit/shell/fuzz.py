#!/usr/bin/env python3
"""Crash and hang fuzzing of the kcos shell.

    python3 audit/shell/fuzz.py [--seed N] [--count N] [--jobs N]

Generates COUNT inputs (random bytes, random shell punctuation, mutated
valid scripts), runs each through /bin/sh as a script file, on stdin, and
with -c when the input has no NUL byte and fits an argument. Reports every
run that ended with a signal, status 101 (panic or out of memory) or the
time limit. Inputs behind such a run are kept in work/fuzz-crash/.
"""
import argparse, base64, collections, io, os, random, subprocess, sys, tarfile
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.environ.get("IMG", "kcos-audit")
META = b"'\"\\$ {}:-|&;<>()#\n\t\r =~*?[`!@01239aAzZ_/.+%^,"
FRAG = [b"${", b"}", b":-", b"$@", b"$*", b"\"$@\"", b"&&", b"||", b">>", b">&", b"<&", b"2>&1", b"\\\n", b"\\\r\n",
        b"\r\n", b"$(", b"`", b"<<", b"set -e\n", b"set -- ", b"shift ", b"exit ", b"wait ", b"exec ", b"cd ",
        b"export ", b"unset ", b"umask ", b"command ", b"command -v ", b": ", b"${A:-", b"${1:-", b"$?", b"$$", b"$!",
        b"$#", b"$-", b"$0", b"${10}", b"99999999999999999999", b"18446744073709551615", b"18446744073709551616",
        b"4294967296", b"2147483648", b"-1", b"1023", b"1024", b">&-", b"<&-", b"A=", b"IFS=", b"PATH=", b"PWD=",
        b"OLDPWD=", b"HOME=", b"\x00", b"\xff", b"\x80", b"\x1b[31m", b"#", b"'", b'"', b"&", b"|", b";", b"\n",
        b"true", b"false", b"echo ", b"/bin/true", b"cat", b"sh -c ", b"sh ", b"env", b"if", b"then", b"fi", b"{", b"!",
        b"~", b"*", b"[", b"?", b"(", b")", b"=", b"+e", b"-x", b"--", b"-", b"ls", b"pwd", b"kill ", b"sleep 0", b"&\n",
        b"wait\n", b"wait $!\n", b"cd -\n", b"exec 3>&1\n", b"exec >&-\n", b"exec <&-\n", b"exec 2>&-\n"]


def seeds(r):
    out = [s.encode() for _, s, _ in gen.generate(r.randrange(1 << 30), 150)]
    cases = os.path.join(HERE, "..", "..", "test", "cases")
    if os.path.isdir(cases):
        for n in sorted(os.listdir(cases)):
            if n.endswith(".sh"):
                out.append(open(os.path.join(cases, n), "rb").read())
    return out


def mutate(r, s):
    s = bytearray(s)
    for _ in range(r.randint(1, 6)):
        k = r.randint(0, 8)
        p = r.randrange(len(s) + 1)
        if k == 0 and s:
            s[r.randrange(len(s))] = r.randrange(256)
        elif k == 1:
            s[p:p] = r.choice(FRAG)
        elif k == 2 and s:
            q = min(len(s), p + r.randint(1, 20))
            del s[p:q]
        elif k == 3 and s:
            q = min(len(s), p + r.randint(1, 40))
            s[p:p] = s[p:q] * r.randint(1, 5)
        elif k == 4:
            s[p:p] = bytes(r.choice(META) for _ in range(r.randint(1, 8)))
        elif k == 5 and s:
            del s[p:]
        elif k == 6 and s:
            i = r.randrange(len(s))
            s[i] ^= 1 << r.randrange(8)
        elif k == 7:
            s[p:p] = r.choice(FRAG) * r.randint(2, 50)
        else:
            a, b = sorted((r.randrange(len(s) + 1), r.randrange(len(s) + 1)))
            s[p:p] = s[a:b]
    return bytes(s[:20000])


def inputs(seed, count):
    r = random.Random(seed)
    sd = seeds(r)
    out = []
    for i in range(count):
        k = i % 10
        if k == 0:
            b = bytes(r.randrange(256) for _ in range(r.randint(1, 300)))
        elif k == 1:
            b = bytes(r.choice(META) for _ in range(r.randint(1, 200)))
        elif k == 2:
            b = b"".join(r.choice(FRAG) for _ in range(r.randint(1, 60)))
        elif k == 3:
            b = mutate(r, b"".join(r.choice(FRAG) for _ in range(r.randint(1, 30))))
        else:
            b = mutate(r, r.choice(sd))
        out.append(b)
    return out


def run_shard(args):
    idx, items, limit = args
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for name, data in items:
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mode = 0o644
            t.addfile(ti, io.BytesIO(data))
    cmd = ["timeout", "3000", "docker", "run", "--rm", "-i", "--platform", "linux/arm64",
           "--name", "kcos-audit-shell-fuzz-%d-%d" % (os.getpid(), idx),
           "--memory", "512m", "--memory-swap", "512m", "--pids-limit", "128", "-e", "LIMIT=%d" % limit,
           "-v", os.path.join(HERE, "infuzz.sh") + ":/infuzz.sh:ro",
           "--entrypoint", "/bb/busybox", IMG, "sh", "/infuzz.sh"]
    p = subprocess.run(cmd, input=buf.getvalue(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return idx, p.returncode, p.stdout.decode("latin1"), p.stderr.decode("latin1")[-300:]


def run(items, jobs=4, limit=5):
    """items: [(name, bytes)]. Returns {(name, mode): (status, stderr head)} and whether every shard finished."""
    shards = [(k, items[k::jobs], limit) for k in range(jobs) if items[k::jobs]]
    res, complete = {}, True
    with ThreadPoolExecutor(jobs) as ex:
        for idx, rc, out, err in ex.map(run_shard, shards):
            lines = out.splitlines()
            if not lines or lines[-1] != "DONE":
                complete = False
                sys.stderr.write("shard %d did not finish (docker status %d): %s\n" % (idx, rc, err))
            for line in lines:
                f = line.split(" ")
                if len(f) >= 3:
                    err = base64.b64decode(f[3]) if len(f) > 3 and f[3] not in ("", "-") else b""
                    res[(f[0], f[1])] = (int(f[2]), err, "RAN-THEN-SYNTAX-ERROR" in f)
    return res, complete


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=20000)
    ap.add_argument("--jobs", type=int, default=4)
    a = ap.parse_args()
    data = inputs(a.seed, a.count)
    items = []
    for i, b in enumerate(data):
        ok_c = b"\0" not in b and len(b) < 100000
        items.append(("%06d%s" % (i, ".c" if ok_c else ".n"), b": >/tmp/mark\n" + b))
    # Controls: the harness must see a hang and a signal death when there is one.
    items.append(("control-hang.c", b"sleep 100\n:\n"))
    items.append(("control-segv.c", b"kill -11 $$\n:\n"))
    res, complete = run(items, a.jobs)
    print("controls: hang -> %s (want 137), SIGSEGV -> %s (want 139)" % (res.get(("control-hang.c", "file"), ("?",))[0], res.get(("control-segv.c", "file"), ("?",))[0]))
    by_name = dict(items)
    status = collections.Counter()
    modes = collections.Counter()
    bad = []
    ran_then = []
    for (name, mode), (rc, err, flagged) in sorted(res.items()):
        if flagged:
            ran_then.append((name, mode))
        modes[mode] += 1
        status[rc] += 1
        if name.startswith("control"):
            continue
        # 153 is SIGXFSZ: the harness limits file size and some inputs feed a file to itself
        if rc == 101 or (129 <= rc <= 192 and rc != 153):
            bad.append((name, mode, rc, err))
    print("inputs: %d (seed %d); runs: %d %s; all shards finished: %s" % (len(items), a.seed, len(res), dict(modes), complete))
    print("exit statuses:", ", ".join("%d: %d" % kv for kv in sorted(status.items())))
    crash = os.path.join(HERE, "work", "fuzz-crash")
    for name, mode, rc, err in bad:
        os.makedirs(crash, exist_ok=True)
        open(os.path.join(crash, "s%d-%s" % (a.seed, name)), "wb").write(by_name[name])
        print("BAD %s %s status %d stderr=%r input=%r" % (name, mode, rc, err[:80], by_name[name][:150]))
    print("bad runs (signal, 101 or time limit): %d" % len(bad))
    # A nested `sh -c` or `sh FILE` started by the input reports its own syntax
    # errors while the outer script runs; those are listed here too and have
    # to be told apart by looking at the input.
    print("file/-c runs that created the marker and printed a syntax error: %d" % len(ran_then))
    for name, mode in ran_then[:40]:
        print("RAN-THEN-SYNTAX-ERROR %s %s input=%r" % (name, mode, by_name[name][:400]))


if __name__ == "__main__":
    main()
