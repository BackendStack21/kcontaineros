#!/usr/bin/env python3
"""Join the eight matrix runs and hold them against what the README says.

Writes results/MATRIX.tsv (every attempt, eight columns) and prints
  - VIOLATION: allowed under init although the README says it is refused
  - OVER:      refused under init, allowed without init, in a place the
               README calls writable (something the README does not mention)
  - counts of attempts that only the lockdown refuses.
"""
import os, sys, collections
here = os.path.dirname(os.path.abspath(__file__))
cols = [(u, p, m) for u in ("nobody", "root") for p in ("default", "privileged") for m in ("init", "control")]
data = collections.OrderedDict()
for c in cols:
    f = os.path.join(here, "results", "matrix-%s-%s-%s.tsv" % c)
    for line in open(f, errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 3:
            continue
        data.setdefault((parts[0], parts[1]), {})[c] = parts[2]

PROGRAM_TOPS = ("/bb", "/bin", "/sbin", "/usr", "/app")
EXEC_DIRS = ("/bb", "/bin", "/sbin", "/usr", "/app/bin")
ALLOWED_DEV = {"/dev/" + n for n in "null zero full random urandom tty console ptmx pts/ptmx stdin stdout stderr fd/1 core".split()}
MUTATE = {"open-write", "open-append", "create", "mkdir", "mknod-fifo", "mknod-chr", "bind-socket", "symlink",
          "link-within", "link-out", "link-in", "rename-in", "rename-file-out", "rename-dir-out", "exchange",
          "ftruncate", "truncate", "unlink", "rmdir", "prep-copy"}
META = {"chmod", "chown", "utimes", "setxattr"}          # README: root may change these
under = lambda path, tops: any(path == t or path.startswith(t + "/") for t in tops)
ok = lambda r: r is not None and (r == "ok" or r.startswith("ioctl:") or r.startswith("ran:") or "=ok" in r)

def must_refuse(target, op, user):
    """True if the README says this is refused under init."""
    if op in ("exec", "execveat-fd", "exec-procfd") or op.startswith("exec-") or op == "tmpfile-exec" or op == "memfd_create":
        if op in ("exec-bb", "exec-script-with-program-dir-interpreter"):
            return False if op == "exec-bb" else True       # the script file itself is in a writable directory
        if op in ("exec-through-symlink-to-program-dir", "exec-through"):   # /lnk -> /app, /lnk/bin is /app/bin
            return False
        if target in ("/proc/self/exe",):
            return False
        if op == "exec-hardlink-of-program":
            return True
        return not under(target, EXEC_DIRS)
    if target == "/" and op != "list":
        return True
    if under(target, PROGRAM_TOPS) and op in MUTATE:
        return True
    if target == "/lnk" and op in ("create-through", "unlink"):
        return True
    if target.startswith("/dev"):
        if target == "/dev" and op not in ("list", "chmod-null"):
            return True
        if target in ("/dev/pts", "/dev/mqueue") and op not in ("list",):
            return True
        if target not in ALLOWED_DEV and target not in ("/dev", "/dev/shm", "/dev/pts", "/dev/mqueue") and op != "present":
            return True                                     # "Only the standard devices can be opened"
    if user == "root" and (target.startswith("/proc") or target.startswith("/sys")) and op in ("open-append", "open-rdwr"):
        return True
    return False

# /etc, /home, /run and /var are writable to Landlock as well, but their mode is 0555 and root
# has no CAP_DAC_OVERRIDE under init: what is refused there is refused by file permissions.
WRITABLE = ("/tmp", "/var/tmp", "/w", "/vol", "/tfs", "/tfsnoexec", "/dev/shm", "/opt", "/srv")
out = open(os.path.join(here, "results", "MATRIX.tsv"), "w")
out.write("target\toperation\t" + "\t".join("%s/%s/%s" % c for c in cols) + "\n")
viol, over, lock = [], [], collections.Counter()
for (t, op), row in data.items():
    out.write("%s\t%s\t%s\n" % (t, op, "\t".join(row.get(c, "-") for c in cols)))
    for u in ("nobody", "root"):
        for p in ("default", "privileged"):
            i, c = row.get((u, p, "init")), row.get((u, p, "control"))
            if ok(i) and must_refuse(t, op, u):
                viol.append((t, op, u, p, i, c))
            if not ok(i) and ok(c):
                lock[(u, p)] += 1
                if under(t, WRITABLE) and op in (MUTATE | META | {"read", "list", "mmap-exec"}) and not (
                        u == "root" and op in ("mknod-chr", "chown")):
                    over.append((t, op, u, p, i, c))
out.close()
print("attempts per run:", {"%s/%s/%s" % c: sum(1 for r in data.values() if c in r) for c in cols})
print("distinct (target, operation) rows:", len(data))
print("refused under init but allowed without it:", {"%s/%s" % k: v for k, v in sorted(lock.items())})
print("\nVIOLATION (allowed under init, README says refused): %d" % len(viol))
for v in viol:
    print("  %-22s %-28s %-6s %-10s init=%s control=%s" % v)
print("\nOVER (refused under init in a place the README calls writable): %d" % len(over))
for v in over:
    print("  %-22s %-28s %-6s %-10s init=%s control=%s" % v)
