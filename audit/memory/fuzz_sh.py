#!/usr/bin/env python3
"""Crash fuzzing of the shell's parser and expander (track: memory, part d).

usage: python3 audit/memory/fuzz_sh.py [N] [SEED]      (from the repo root)

Looks for panics ("kcontaineros: internal error", exit 101), allocator
failures ("out of memory") and signals (SIGSEGV = 139, ...). A hang shows as
the whole run timing out (30 min) after the last progress line.
It does not judge whether the shell's answer is the right one.

Mode A, N cases: the script is given as a file with "\\n(" appended. "(" is
always a syntax error, and a script file is checked completely before its
first command runs, so nothing is executed; because parsing also expands,
the expander runs over every word. Expected of every case: exit status 2
and one line "sh: syntax error: ..." on stderr, nothing on stdout.

Mode B, N/4 cases: the script is given on stdin, where each line runs as
it is read. The vocabulary has only builtins and harmless tools; it runs as
nobody under init in a throwaway container. Expected: no crash marker.

Everything runs in one container of image kcos-audit-memory-img (see
build.sh), removed afterwards.
"""
import io
import random
import subprocess
import sys
import tarfile

N = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
SEED = int(sys.argv[2]) if len(sys.argv) > 2 else 1
IMAGE = "kcos-audit-memory-img"
rnd = random.Random(SEED)

ATOMS = [
    b"'", b'"', b"\\", b"$", b"${", b"}", b":-", b":", b"-", b"=", b"#", b"@", b"*", b"?", b"!",
    b"~", b"`", b"(", b")", b"[", b"|", b"||", b"&", b"&&", b";", b"<", b">", b">>", b"<<", b">&",
    b"<&", b"&>", b"\n", b"\r\n", b"\r", b"\\\n", b"\\\r\n", b" ", b"\t", b"  ",
    b"$@", b"$*", b"$#", b"$?", b"$$", b"$!", b"$-", b"$0", b"$1", b"$2", b"$3", b"$9", b"${10}",
    b'"$@"', b'"$*"', b"${@}", b"${*}", b"${#}", b"$A", b"$B", b"$EMPTY", b"$UNSET", b"$SP", b"$PATH",
    b"${A}", b"${UNSET:-", b"${A:-", b"${EMPTY:-", b"${1:-", b"${@:-", b"${:-", b"${A:=", b"${A:?",
    b"${#A}", b"${A%", b"$'", b"$(", b"$((", b"A=", b"B=", b"IFS=", b"PATH=", b"A=$A$A",
    b"0", b"1", b"2", b"7", b"1023", b"1024", b"99999999999999999999", b"18446744073709551615",
    b"echo", b":", b"true", b"false", b"cd", b"export", b"unset", b"set", b"shift", b"exit",
    b"wait", b"command", b"exec", b"umask", b"env", b"-e", b"-x", b"+e", b"-ex", b"-u", b"--", b"-v",
    b"-c", b"-P", b"-", b"+", b"if", b"then", b"fi", b"for", b"{", b"!", b"[[", b".", b"eval", b"read",
    b"x", b"abc", b"/", b"/nonexistent", b"/dev/null", b".", b"..", b"\x80", b"\xff", b"\x7f", b"\x1b[31m",
    b"\x01", b"a b", b"_", b"OLDPWD", b"PWD=", b"HOME=", b"2>&1", b"2>/dev/null", b">/dev/null",
    b"</dev/null", b">&-", b"<&-", b"9>&1", b"1023>&1", b"1024>&1", b">&1023", b">&9999999999",
]


def case():
    n = rnd.choice([1, 2, 3, 4, 6, 8, 12, 20, 40])
    out = b"".join(rnd.choice(ATOMS) + rnd.choice([b"", b"", b" "]) for _ in range(n))
    return out.replace(b"\0", b"")


def tar_of(cases_a, cases_b):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for kind, cases in (("a", cases_a), ("b", cases_b)):
            for i, c in enumerate(cases):
                info = tarfile.TarInfo("f/%s%06d" % (kind, i))
                info.size = len(c)
                info.mode = 0o644
                tar.addfile(info, io.BytesIO(c))
    return buf.getvalue()


cases_a = [case() + b"\n(" for _ in range(N)]
cases_b = [case() + b"\n" for _ in range(N // 4)]

LOOP = r"""
export PATH=/bb:/bin
mkdir /tmp/w && cd /tmp/w && tar x
export A=value B='two  words' EMPTY= SP=' ' HOME=/nonexistent
na=0; nb=0; bad=0; flaky=0; b0=0; b2=0
for f in f/a*; do
  na=$((na+1)); [ $((na % 5000)) = 0 ] && echo "progress: A $na"
  /bin/sh "$f" one "two words" "" four >/tmp/o 2>/tmp/e </dev/null; rc=$?
  IFS= read -r first </tmp/e
  case "$rc:$first" in
    "2:sh: syntax error: "*) [ -s /tmp/o ] && { bad=$((bad+1)); echo "ANOMALY-A $f: wrote to stdout"; } ;;
    *) # once more: only what happens twice is the shell's doing
       /bin/sh "$f" one "two words" "" four >/tmp/o 2>/tmp/e2 </dev/null; rc2=$?
       IFS= read -r second </tmp/e2
       case "$rc2:$second" in
         "2:sh: syntax error: "*) flaky=$((flaky+1)); echo "TRANSIENT-A $f rc=$rc: $first | df: $(df -k /tmp | tail -1)" ;;
         *) bad=$((bad+1)); echo "ANOMALY-A $f rc=$rc: $first" ;;
       esac ;;
  esac
done
# mode B: each line runs as it is read (the whole container runs as nobody)
mkdir /tmp/cwd; cd /tmp/cwd; ln -s /tmp/w/f f
for f in f/b*; do
  nb=$((nb+1)); echo "$f" >/tmp/current
  /bin/sh <"$f" >/tmp/o 2>/tmp/e; rc=$?
  [ $rc = 2 ] && b2=$((b2+1)); [ $rc = 0 ] && b0=$((b0+1))
  if grep -q -e "internal error" -e "out of memory" /tmp/e /tmp/o || [ $rc = 139 ] || [ $rc = 137 ] || [ $rc = 134 ] || [ $rc = 135 ] || [ $rc = 132 ] || [ $rc = 101 ]; then
    bad=$((bad+1)); echo "ANOMALY-B $f rc=$rc: $(head -c 200 /tmp/e)"
  fi
done
echo "mode A cases: $na; mode B cases: $nb (exit 0: $b0, exit 2: $b2); anomalies: $bad; not reproduced on an immediate second run: $flaky"
"""

cmd = ["timeout", "1800", "docker", "run", "--rm", "-i", "--platform", "linux/arm64",
       "--name", "kcos-audit-memory-fuzz", "--pids-limit", "256", "--memory", "768m", "--user", "65534:65534",
       # the cases live in memory: one small file each would take 4 KiB of Docker's disk
       "--tmpfs", "/tmp:rw,nosuid,nodev,size=512m,mode=1777",
       IMAGE, "/bb/busybox", "sh", "-c", LOOP]
print("seed=%d: %d parse-only cases, %d stdin cases" % (SEED, len(cases_a), len(cases_b)), flush=True)
res = subprocess.run(cmd, input=tar_of(cases_a, cases_b), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
text = res.stdout.decode("latin-1")
print(text[-6000:])
# show the offending inputs
for line in text.splitlines():
    if line.startswith(("ANOMALY-", "TRANSIENT-")):
        name = line.split()[1].rstrip(":")
        kind, idx = name[2], int(name[3:9])
        src = (cases_a if kind == "a" else cases_b)[idx]
        print("  %s input: %r" % (name, src))
print("docker exit status: %d" % res.returncode)
