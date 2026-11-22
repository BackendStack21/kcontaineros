#!/usr/bin/env python3
"""Crash fuzzing of the utilities' argument handling (track: memory, part d).

usage: python3 audit/memory/fuzz_applets.py [N] [SEED]      (from the repo root)

N argument vectors per utility, built from a vocabulary of options, numbers
at the edges of u8/u32/u64, paths of awkward length (255, 256, 4095, 4096
bytes), empty strings and control bytes. Each is started with exactly that
argv (through /bb/hexec argsfile) as nobody under init, in a scratch
directory, stdin from /dev/null.

Looks for: "kcontaineros: internal error" (a panic, exit 101), "out of
memory", death by signal, and exit statuses a utility never returns (the
utilities return 0, 1, 126 or 127; 2 is the shell's, reachable through
`kcontaineros sh`). It does not judge the output otherwise.

The vocabulary avoids what would disturb the run itself: `sleep` gets only
operands that add up to well under a second or are invalid, `kill` only
process IDs that cannot exist, `cat` and `cp` nothing that never ends (no
/dev/zero or /dev/full to read, no FIFO to open).
"""
import io
import random
import subprocess
import sys
import tarfile

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
SEED = int(sys.argv[2]) if len(sys.argv) > 2 else 1
IMAGE = "kcos-audit-memory-img"
rnd = random.Random(SEED)

LONG = [b"a" * 255, b"a" * 256, b"a/" * 2047 + b"a", b"a/" * 2048, b"/" * 5000, b"a" * 70000]
COMMON = [b"", b"-", b"--", b"-x", b"--help", b".", b"..", b"/", b"//", b"./", b"a", b"b", b"a/", b"a/b", b"d",
          b"d/", b"d/e", b"link", b"dangling", b"loop", b"fifo", b"/dev/null", b"/etc/passwd",
          b"/nonexistent", b"/proc/self/status", b"/proc/self/fd", b"/proc/1", b"/dev", b"\xff\xfe", b"\x1b[2J",
          b"a\nb", b" ", b"-\x00"[:1] + b"\x80", b"=", b"A=1", b"=x", b"A=", b"-a", b"-l", b"-la", b"-r", b"-f",
          b"-rf", b"-p", b"-s", b"-i", b"-u", b"-n", b"-e", b"-E", b"-ne", b"-v", b"-c"] + LONG
NUMS = [b"0", b"00", b"000", b"0000", b"7", b"8", b"644", b"0644", b"7777", b"77777", b"1777", b"4755",
        b"4294967294", b"4294967295", b"4294967296", b"18446744073709551615", b"18446744073709551616",
        b"99999999999999999999999", b"-1", b"+1", b"0x10", b"1e3", b"65534", b"65534:65534", b"0:0", b":",
        b"1:", b":1", b"1:2:3", b"4294967294:4294967294", b"4294967295:0"]
ECHO = [b"\\", b"\\\\", b"\\n", b"\\c", b"\\0", b"\\0777", b"\\08", b"\\x", b"\\xff", b"\\xfg", b"\\x4", b"\\q",
        b"\\e[31m", b"a\\", b"\\0\\", b"\\x\\", b"-n", b"-e", b"-E", b"-neE", b"-nx", b"-", b"--", b"x" * 5000,
        b"\\0" * 3000, b"\\x41" * 2000]
SLEEP = [b"0", b"0.0", b".0", b"0.", b".", b"", b"s", b"m", b"0s", b"0m", b"0h", b"0d", b"0.000000001",
         b"0.0000000001", b"0.00000000000000000000001", b"1e", b"-1", b"+0", b"0x0", b"0.0.0", b"0.0s", b".s",
         b"0,1", b"18446744073709551615", b"18446744073709551616", b"18446744073709551615d",
         b"213503982334602d", b"0.x", b"0.0000000009", b"0.\xff", b"0./", b"0.:", b"--",
         b"infinit", b"0ms", b"0 ", b" 0", b"00000000000000000000000000", b"0.000000001d"]
KILL = [b"-0", b"-9", b"-15", b"-64", b"-65", b"-TERM", b"-SIGTERM", b"-SIGSIG", b"-term", b"-s", b"-s9", b"--",
        b"-", b"-l", b"-18446744073709551615", b"-KILL", b"TERM", b"0", b"-1", b"999999999", b"2147483647",
        b"2147483648", b"4294967297", b"18446744073709551617", b"x", b"", b"+5", b" 5", b"-s", b"HUP", b"SIGHUP"]

# Opening a FIFO nobody else has open blocks, for cat (reading) and for cp (writing to it).
NOFIFO = [c for c in COMMON if c != b"fifo"]

SPECS = {
    "cat": NOFIFO, "chmod": NUMS + COMMON, "chown": NUMS + COMMON, "cp": NOFIFO, "echo": ECHO + COMMON[:12],
    "env": COMMON + [b"true", b"/bin/true", b"-u", b"A", b"PATH=/nonexistent", b"PATH="],
    "false": COMMON, "kill": KILL, "ln": COMMON, "ls": COMMON, "mkdir": COMMON, "mv": COMMON, "ps": COMMON[:8],
    "pwd": COMMON[:8], "rm": COMMON, "sleep": SLEEP, "touch": COMMON, "true": COMMON,
    "uname": [b"-a", b"-n", b"-r", b"-m", b"-s", b"-x", b"", b"--", b"-", b"-am", b"-a", b"x" * 300],
    "kcontaineros": [b"--version", b"-V", b"--list", b"--help", b"-h", b"", b"init", b"sh", b"true", b"echo",
                     b"kcontaineros", b"--", b"-c", b":", b"x"],
}


def vector(name):
    vocab = SPECS[name]
    n = rnd.choice([0, 1, 1, 2, 2, 3, 3, 4, 6])
    args = [rnd.choice(vocab) for _ in range(n)]
    return b"".join(a + b"\0" for a in [b"/bin/" + name.encode()] + args)


cases = []
for name in sorted(SPECS):
    for _ in range(N):
        cases.append((name, vector(name)))

buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as tar:
    for i, (name, c) in enumerate(cases):
        info = tarfile.TarInfo("f/%06d" % i)
        info.size = len(c)
        info.mode = 0o644
        tar.addfile(info, io.BytesIO(c))

LOOP = r"""
export PATH=/bb:/bin
mkdir /tmp/c && cd /tmp/c && tar x
n=0; bad=0; r0=0; r1=0; r2=0; r126=0; r127=0
for f in /tmp/c/f/*; do
  n=$((n+1))
  # a fresh scratch directory (the whole container runs as nobody: under init
  # root has no capability left to change user with)
  if [ ! -d /tmp/w/d ] || [ ! -e /tmp/w/a ] || [ $((n % 50)) = 0 ]; then
    # kContainerOS's own rm: busybox's cannot remove the deep trees `mkdir -p` makes
    chmod -R u+rwx /tmp/w 2>/dev/null; /bin/rm -rf /tmp/w 2>/dev/null; [ -e /tmp/w ] && mv /tmp/w /tmp/old.$n
    mkdir -p /tmp/w/d/e; echo data >/tmp/w/a; echo more >/tmp/w/d/e/f; ln -s a /tmp/w/link
    ln -s /nonexistent /tmp/w/dangling; ln -s loop /tmp/w/loop; mkfifo /tmp/w/fifo
  fi
  cd /tmp/w
  /bb/hexec argsfile "$f" >/tmp/o 2>/tmp/e </dev/null; rc=$?
  case $rc in 0|1|2|126|127) ok=1; eval "r$rc=\$((r$rc+1))" ;; *) ok=0 ;; esac
  if [ $ok = 0 ] || grep -q -e "internal error" -e "out of memory" /tmp/e; then
    bad=$((bad+1)); echo "ANOMALY $f rc=$rc: $(head -c 160 /tmp/e)"
  fi
done
echo "cases: $n; exit 0: $r0, 1: $r1, 2: $r2, 126: $r126, 127: $r127; anomalies: $bad"
"""

cmd = ["timeout", "1800", "docker", "run", "--rm", "-i", "--platform", "linux/arm64",
       "--name", "kcos-audit-memory-fuzz-applets", "--pids-limit", "256", "--memory", "768m", "--user", "65534:65534",
       # the cases live in memory: one small file each would take 4 KiB of Docker's disk
       "--tmpfs", "/tmp:rw,nosuid,nodev,size=512m,mode=1777",
       IMAGE, "/bb/busybox", "sh", "-c", LOOP]
print("seed=%d: %d utilities x %d argument vectors = %d cases" % (SEED, len(SPECS), N, len(cases)), flush=True)
res = subprocess.run(cmd, input=buf.getvalue(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
text = res.stdout.decode("latin-1")
print(text[-8000:])
for line in text.splitlines():
    if line.startswith("ANOMALY "):
        idx = int(line.split()[1].rsplit("/", 1)[1])
        args = cases[idx][1].split(b"\0")[:-1]
        print("  %06d argv: %r" % (idx, [a if len(a) < 60 else a[:20] + b"...(%d bytes)" % len(a) for a in args]))
print("docker exit status: %d" % res.returncode)
