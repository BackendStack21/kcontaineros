#!/usr/bin/env python3
"""Interpreter and checker for the seccomp filter kContainerOS installs.

Works on the bytes read back from the kernel by dump.sh (out/filter-*.txt),
not on the source. Subcommands:

  bpf.py programs            which distinct programs were read, from which processes
  bpf.py verify              static checks: jumps, returns, what the accumulator holds at each test
  bpf.py table               verdict for every syscall number 0..1100 (writes out/table.tsv)
  bpf.py args                the argument-dependent clauses over boundary values
  bpf.py arch                foreign architectures and odd syscall numbers
  bpf.py source              compare with the numbers written in src/lock.rs
  bpf.py claims              compare with what README.md says is refused
  bpf.py docker              what Docker's default filter refuses and this one lets through
  bpf.py compare INIT CTRL   check probe output (sysprobe safe) against the interpreter
  bpf.py refused             print the numbers 0..1100 the filter refuses (for sysprobe raw)
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
AARCH64 = 0xC00000B7
M32 = 0xFFFFFFFF
ERRNO = {1: "EPERM", 38: "ENOSYS", 114: "EALREADY"}


# ------------------------------------------------------------------ loading
def load_dump(path):
    """-> list of (pid, index, [(code, jt, jf, k)])"""
    progs, cur = [], None
    for line in open(path):
        m = re.match(r"pid (\d+) filter (\d+) len (\d+)", line)
        if m:
            cur = []
            progs.append((int(m.group(1)), int(m.group(2)), cur))
            continue
        m = re.match(r"([0-9a-f]{4}) ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{8})$", line.strip())
        if m and cur is not None:
            cur.append(tuple(int(x, 16) for x in m.groups()))
        elif not m:
            cur = None
    return progs


def all_dumps():
    res = {}
    for f in sorted(os.listdir(OUT)):
        if f.startswith("filter-") and f.endswith(".txt"):
            res[f] = load_dump(os.path.join(OUT, f))
    return res


def kcos_program(which="filter-init-root-privileged.txt", pid=None):
    """The program on the command started by init (the highest PID dumped)."""
    progs = load_dump(os.path.join(OUT, which))
    progs = [p for p in progs if len(p[2]) and p[0] == max(q[0] for q in progs)]
    return progs[-1][2]  # the newest filter of that process


def names():
    n = {}
    for line in open(os.path.join(HERE, "syscalls_musl.tsv")):
        nr, name = line.split()
        n.setdefault(int(nr), name)
    return n


# -------------------------------------------------------------- interpreter
def seccomp_data(nr, arch, args, ip=0):
    """struct seccomp_data { int nr; u32 arch; u64 ip; u64 args[6]; } little-endian, as 16 u32 words"""
    words = [nr & M32, arch & M32, ip & M32, ip >> 32]
    for a in list(args) + [0] * (6 - len(args)):
        words += [a & M32, (a >> 32) & M32]
    return words


def run(prog, nr, arch=AARCH64, args=(), trace=None):
    """Classic BPF as seccomp accepts it (kernel/seccomp.c seccomp_check_filter).
    Returns the 32-bit action. `trace` collects (pc, source of A) pairs."""
    data = seccomp_data(nr, arch, args)
    A = X = 0
    src = "0"
    mem = [0] * 16
    pc = 0
    while True:
        if pc >= len(prog):
            raise RuntimeError("ran off the end at %d" % pc)
        code, jt, jf, k = prog[pc]
        cls = code & 7
        if cls == 0:  # LD
            mode = code & 0xE0
            if code == 0x20:  # W ABS
                if k % 4 or k >= 64:
                    raise RuntimeError("bad offset %d" % k)
                A = data[k // 4]
                src = {0: "nr", 4: "arch", 8: "ip.lo", 12: "ip.hi"}.get(k, "arg%d.%s" % ((k - 16) // 8, "hi" if k % 8 else "lo"))
            elif mode == 0x00:
                A, src = k, "imm"
            elif mode == 0x60:
                A, src = mem[k], "mem"
            elif mode == 0x80:
                A, src = 64, "len"
            else:
                raise RuntimeError("unsupported LD %#x" % code)
        elif cls == 1:  # LDX
            mode = code & 0xE0
            X = k if mode == 0 else mem[k] if mode == 0x60 else 64
        elif cls == 2:
            mem[k] = A
        elif cls == 3:
            mem[k] = X
        elif cls == 4:  # ALU
            op, v = code & 0xF0, (X if code & 8 else k)
            if op == 0x00: A += v
            elif op == 0x10: A -= v
            elif op == 0x20: A *= v
            elif op == 0x30: A = A // v if v else 0
            elif op == 0x40: A |= v
            elif op == 0x50: A &= v
            elif op == 0x60: A <<= v
            elif op == 0x70: A >>= v
            elif op == 0x80: A = -A
            elif op == 0x90: A = A % v if v else 0
            elif op == 0xA0: A ^= v
            A &= M32
            src += "*"
        elif cls == 5:  # JMP
            op, v = code & 0xF0, (X if code & 8 else k)
            if trace is not None:
                trace.append((pc, src))
            if op == 0x00:
                pc += k
            else:
                t = {0x10: A == v, 0x20: A > v, 0x30: A >= v, 0x40: bool(A & v)}[op]
                pc += jt if t else jf
        elif cls == 6:  # RET
            return (A if code & 0x10 else k) & M32
        elif cls == 7:  # MISC
            if code & 0xF8 == 0: X = A
            else: A = X
        pc += 1


def verdict(action):
    a, d = action & 0xFFFF0000, action & 0xFFFF
    if a == 0x7FFF0000: return "ALLOW"
    if a == 0x80000000: return "KILL_PROCESS"
    if a == 0x00000000: return "KILL_THREAD"
    if a == 0x00050000: return "ERRNO(%s)" % ERRNO.get(d, d)
    if a == 0x00030000: return "TRAP"
    if a == 0x7FC00000: return "USER_NOTIF"
    if a == 0x7FF00000: return "TRACE"
    if a == 0x7FFC0000: return "LOG"
    return "%#x" % action


# ------------------------------------------------------------------ commands
def cmd_programs():
    seen = {}
    for f, progs in all_dumps().items():
        for pid, idx, p in progs:
            seen.setdefault(tuple(p), []).append("%s pid %d filter %d" % (f, pid, idx))
    ref = tuple(kcos_program())
    print("distinct programs read from the kernel: %d" % len(seen))
    for p, where in seen.items():
        diff = [i for i in range(min(len(p), len(ref))) if p[i] != ref[i]] if len(p) == len(ref) else None
        kind = "identical to init's" if diff == [] else \
            "differs from init's at instruction(s) %s: %s" % (diff, [("%04x %02x %02x %08x" % p[i]) for i in diff]) if diff else "another program (not kContainerOS's)"
        print("- %d instructions, %s" % (len(p), kind))
        for w in where:
            print("    " + w)


def cmd_verify():
    prog = kcos_program()
    ok = True
    n = len(prog)
    print("%d instructions" % n)
    loads = sorted({k for c, _, _, k in prog if c == 0x20})
    print("offsets of seccomp_data loaded: %s (0 nr, 4 arch, 16 low half of arg0)" % loads)
    codes = sorted({c for c, _, _, _ in prog})
    print("opcodes used: %s" % ["%#04x" % c for c in codes])
    for pc, (c, jt, jf, k) in enumerate(prog):
        if c & 7 == 5 and c & 0xF0:
            for off in (jt, jf):
                if pc + 1 + off >= n:
                    ok = False
                    print("FAIL: jump out of range at %d" % pc)
    if prog[-1][0] != 0x06:
        ok = False
        print("FAIL: last instruction is not a return")
    # Every reachable (pc, what A holds) pair, by walking all paths: the
    # program only jumps forward, so this is a finite DAG.
    held = {}
    stack = [(0, "0")]
    visited = set()
    falls_off = False
    while stack:
        pc, src = stack.pop()
        if (pc, src) in visited:
            continue
        visited.add((pc, src))
        if pc >= n:
            falls_off = True
            continue
        c, jt, jf, k = prog[pc]
        if c == 0x20:
            stack.append((pc + 1, {0: "nr", 4: "arch", 16: "arg0.lo"}.get(k, "off%d" % k)))
        elif c & 7 == 5:
            held.setdefault(pc, set()).add(src)
            stack.append((pc + 1 + jt, src))
            stack.append((pc + 1 + jf, src))
        elif c == 0x06:
            pass
        else:
            ok = False
            print("FAIL: unexpected opcode %#x at %d" % (c, pc))
    if falls_off:
        ok = False
        print("FAIL: a path runs off the end")
    unreachable = [pc for pc in range(n) if not any(v[0] == pc for v in visited)]
    print("unreachable instructions: %s" % (unreachable or "none"))
    multi = {pc: s for pc, s in held.items() if len(s) != 1}
    print("conditional jumps: %d; reached with more than one kind of value in A: %s" % (len(held), multi or "none"))
    by = {}
    for pc, s in held.items():
        by.setdefault(next(iter(s)), []).append(pc)
    for s, pcs in sorted(by.items()):
        ks = [prog[pc][3] for pc in sorted(pcs)]
        print("  A = %-8s at %3d jump(s); constants compared: %s" % (s, len(pcs), " ".join("%#x" % k if s != "nr" else str(k) for k in ks)))
    # A syscall number tested while A holds an argument would be a hole.
    nrs = set(names())
    for pc in by.get("arg0.lo", []):
        print("  arg test at %d: %s k=%#x" % (pc, {0x15: "JEQ", 0x25: "JGT", 0x45: "JSET"}[prog[pc][0]], prog[pc][3]))
    print("RESULT verify: %s" % ("ok" if ok and not multi and not unreachable else "PROBLEM"))


def arg_dependent(prog, nr):
    tr = []
    run(prog, nr, trace=tr)
    return any(s.startswith("arg") for _, s in tr)


def cmd_table():
    prog = kcos_program()
    nm = names()
    rows, count = [], {}
    for nr in range(0, 1101):
        v = verdict(run(prog, nr))
        note = ""
        if arg_dependent(prog, nr):
            note = "depends on arg0 (verdict shown is for arg0 = 0; see `bpf.py args`)"
        rows.append((nr, nm.get(nr, "-"), v, note))
        count[v] = count.get(v, 0) + 1
    with open(os.path.join(OUT, "table.tsv"), "w") as f:
        f.write("nr\tname\tverdict (aarch64, args 0)\tnote\n")
        for r in rows:
            f.write("%d\t%s\t%s\t%s\n" % r)
    print("wrote out/table.tsv: %d numbers" % len(rows))
    for v, c in sorted(count.items()):
        print("  %-16s %d" % (v, c))
    named = [r for r in rows if r[1] != "-" and r[0] <= 466]
    print("of the %d numbers up to 466 that name a system call on aarch64: %d allowed, %d refused, %d argument-dependent" % (
        len(named), sum(r[2] == "ALLOW" and not r[3] for r in named),
        sum(r[2] != "ALLOW" and not r[3] for r in named), sum(bool(r[3]) for r in named)))
    print("refused (EPERM): " + " ".join("%s(%d)" % (r[1], r[0]) for r in rows if r[2] == "ERRNO(EPERM)"))
    print("refused (ENOSYS) up to 466: " + " ".join("%s(%d)" % (r[1], r[0]) for r in rows if r[2] == "ERRNO(ENOSYS)" and r[0] <= 466))
    print("first/last ENOSYS above: %s .. %s" % (min(r[0] for r in rows if r[2] == "ERRNO(ENOSYS)" and r[0] > 435), max(r[0] for r in rows if r[2] == "ERRNO(ENOSYS)")))
    print("argument-dependent: " + " ".join("%s(%d)" % (r[1], r[0]) for r in rows if r[3]))


def boundary_values(consts):
    vals = {0, 1, M32, 0x7FFFFFFF, 0x80000000}
    for b in range(32):
        vals.add(1 << b)
    for k in consts:
        vals |= {k, (k - 1) & M32, (k + 1) & M32, k ^ M32}
        for b in range(32):
            vals.add(k ^ (1 << b))
    lows = sorted(vals)
    highs = [0, 1, 0x7FFFFFFF, 0x80000000, M32] + sorted(consts)
    return [(h << 32) | l for l in lows for h in highs]


def cmd_args():
    prog = kcos_program()
    nm = names()
    dep = [nr for nr in range(0, 1101) if arg_dependent(prog, nr)]
    total = 0
    for nr in dep:
        tr = []
        run(prog, nr, trace=tr)
        consts = set()
        # constants on any arg test this syscall can reach
        for a in (0, M32, 0x4B434F53, 40, 0x7E020000):
            t2 = []
            run(prog, nr, args=(a,), trace=t2)
            consts |= {prog[pc][3] for pc, s in t2 if s.startswith("arg")}
        vals = boundary_values(consts)
        res = {}
        for a in vals:
            # the other five arguments must not matter: vary them too
            v = verdict(run(prog, nr, args=(a, 0, 0, 0, 0, 0)))
            v2 = verdict(run(prog, nr, args=(a, M32 << 32 | M32, 40, 0x7E020000, 0x4B434F53, M32)))
            assert v == v2, "other arguments change the verdict"
            res.setdefault(v, []).append(a)
            total += 2
        # the high half of arg0 must not matter
        for v, lst in res.items():
            pass
        by_low = {}
        for v, lst in res.items():
            for a in lst:
                by_low.setdefault(a & M32, set()).add(v)
        high_matters = {l: s for l, s in by_low.items() if len(s) > 1}
        print("%s (%d): %d values of arg0 evaluated; constants in the clause: %s" % (
            nm.get(nr, "?"), nr, len(vals), " ".join("%#x" % c for c in sorted(consts))))
        for v, lst in sorted(res.items()):
            lows = sorted({a & M32 for a in lst})
            print("   %-16s for %d values; low halves e.g. %s" % (v, len(lst), " ".join("%#x" % l for l in lows[:6])))
        print("   high 32 bits of arg0 change the verdict: %s" % ("YES %s" % high_matters if high_matters else "no"))
        if nr == 220:
            refused = [b for b in range(32) if verdict(run(prog, nr, args=(1 << b,))) != "ALLOW"]
            print("   single flag bits refused: %s" % " ".join("%#x" % (1 << b) for b in refused))
            known = {0x20000: "NEWNS", 0x2000000: "NEWCGROUP", 0x4000000: "NEWUTS", 0x8000000: "NEWIPC",
                     0x10000000: "NEWUSER", 0x20000000: "NEWPID", 0x40000000: "NEWNET"}
            print("   namespace flags of clone(2): " + " ".join("%s=%s" % (n, verdict(run(prog, nr, args=(f,)))) for f, n in known.items()))
            print("   CLONE_NEWTIME (0x80) = %s: lies in the exit-signal byte, clone(2) cannot pass it (unshare/clone3 only)" % verdict(run(prog, nr, args=(0x80,))))
        if nr == 198:
            fams = [f for f in range(0, 256) if verdict(run(prog, nr, args=(f,))) != "ALLOW"]
            print("   families 0..255 refused: %s" % fams)
        if nr == 92:
            ok = [p for p in boundary_values(consts) if verdict(run(prog, nr, args=(p,))) == "ALLOW"]
            print("   allowed low halves: %s" % sorted({"%#x" % (p & M32) for p in ok}))
        if nr == 167:
            for op in (0x4B434F53, 0x4B434F46):
                print("   prctl(%#x) -> %s" % (op, verdict(run(prog, nr, args=(op,)))))
            real = [o for o in range(0, 100) if verdict(run(prog, nr, args=(o,))) != "ALLOW"]
            print("   real prctl options 0..99 not allowed: %s" % (real or "none"))
    print("argument-dependent syscalls: %d; evaluations: %d" % (len(dep), total))


def cmd_arch():
    prog = kcos_program()
    archs = {
        "AUDIT_ARCH_ARM (aarch32 compat)": 0x40000028, "AUDIT_ARCH_ARMEB": 0x00000028,
        "AUDIT_ARCH_X86_64": 0xC000003E, "AUDIT_ARCH_I386": 0x40000003,
        "AUDIT_ARCH_RISCV64": 0xC00000F3, "aarch64 without the 64-bit flag": 0x400000B7,
        "aarch64 without the LE flag": 0x800000B7, "EM_AARCH64 only": 0xB7,
        "0": 0, "0xffffffff": M32, "aarch64-1": AARCH64 - 1, "aarch64+1": AARCH64 + 1,
    }
    for b in range(32):
        archs["aarch64 ^ bit %d" % b] = AARCH64 ^ (1 << b)
    bad = 0
    total = 0
    for name, arch in archs.items():
        vs = {}
        for nr in list(range(0, 1101)) + [M32, 0x7FFFFFFF, 0x80000000]:
            for a0 in (0, 40, 0x7E020000, M32, 0x4B434F53):
                vs[verdict(run(prog, nr, arch=arch, args=(a0,)))] = 1
                total += 1
        if set(vs) != {"KILL_PROCESS"}:
            bad += 1
            print("FAIL %s (%#x): %s" % (name, arch, sorted(vs)))
    print("foreign arch values tried: %d (x 1104 numbers x 5 arg0 values = %d evaluations); not answered KILL_PROCESS: %d" % (len(archs), total, bad))
    print("odd numbers under aarch64:")
    for nr in (466, 467, 1100, 0x3FFFFFFF, 0x40000000 | 279, 0x7FFFFFFF, 0x80000000, 0x80000000 | 279, M32 - 1, M32):
        print("  nr %#x -> %s" % (nr, verdict(run(prog, nr))))
    # every number above 466 in a wider sweep
    wide = {verdict(run(prog, nr)) for nr in range(467, 70000)} | {verdict(run(prog, (1 << b) | low)) for b in range(9, 32) for low in range(0, 467)}
    print("numbers 467..69999 and every number 0..466 with one high bit (9..31) set: %s" % sorted(wide))
    print("RESULT arch: %s" % ("ok" if not bad and wide == {"ERRNO(ENOSYS)"} else "PROBLEM"))


def source_numbers():
    src = open(os.path.join(HERE, "..", "..", "src", "lock.rs")).read()
    body = src[src.index("const DENIED"):]
    body = body[:body.index("];")]
    return [(int(m.group(1)), m.group(2)) for m in re.finditer(r"^\s*(\d+),\s*// (\w+)", body, re.M)]


def cmd_source():
    prog = kcos_program()
    nm = names()
    denied = source_numbers()
    table = {nr for nr in range(0, 467) if verdict(run(prog, nr)) == "ERRNO(EPERM)" and not arg_dependent(prog, nr)}
    print("DENIED in src/lock.rs: %d entries, %d distinct" % (len(denied), len({d[0] for d in denied})))
    print("EPERM regardless of arguments in the kernel's copy: %d" % len(table))
    print("in source, not refused by the kernel's copy: %s" % (sorted({d[0] for d in denied} - table) or "none"))
    print("refused by the kernel's copy, not in source: %s" % (sorted(table - {d[0] for d in denied}) or "none"))
    wrong = [(nr, c, nm.get(nr)) for nr, c in denied if nm.get(nr) != c]
    print("source comments that do not name the number's syscall (musl's aarch64 table): %s" % (wrong or "none"))
    print("expected length 31 + 2*%d = %d; read from kernel: %d" % (len(denied), 31 + 2 * len(denied), len(prog)))
    ok = table == {d[0] for d in denied} and not wrong and len(prog) == 31 + 2 * len(denied)
    print("RESULT source: %s" % ("ok" if ok else "PROBLEM"))


# What the README's "Reduced kernel surface" row and the memory-file row say
# is refused, as system calls; and others that reach a similar effect.
CLAIMS = [
    ("ptrace", ["ptrace"]),
    ("reading or writing another process's memory", ["process_vm_readv", "process_vm_writev"]),
    ("new namespaces", ["unshare", "setns", "clone3", "clone:0x10000000"]),
    ("mounts", ["mount", "umount2", "pivot_root", "open_tree", "move_mount", "fsopen", "fsconfig", "fsmount", "fspick", "mount_setattr", "open_tree_attr"]),
    ("chroot", ["chroot"]),
    ("kernel modules", ["init_module", "finit_module", "delete_module"]),
    ("bpf", ["bpf"]),
    ("io_uring", ["io_uring_setup", "io_uring_enter", "io_uring_register"]),
    ("perf", ["perf_event_open"]),
    ("keyrings", ["add_key", "request_key", "keyctl"]),
    ("clock changes", ["clock_settime", "settimeofday", "adjtimex", "clock_adjtime"]),
    ("hostname changes", ["sethostname", "setdomainname"]),
    ("sockets to the hypervisor (AF_VSOCK)", ["socket:40"]),
    ("switching off address randomisation", ["personality:0x40000"]),
    ("memory files (memfd_create) cannot be created", ["memfd_create", "memfd_secret"]),
    ("newer than the filter knows -> not implemented", ["open_tree_attr", "file_getattr", "file_setattr", "listns"]),
]
RELATED = ["execveat", "execve", "open_by_handle_at", "name_to_handle_at", "pidfd_open", "pidfd_send_signal", "pidfd_getfd",
           "process_madvise", "process_mrelease", "kcmp", "kexec_load", "kexec_file_load", "swapon", "swapoff",
           "quotactl", "quotactl_fd", "landlock_create_ruleset", "landlock_add_rule", "landlock_restrict_self",
           "seccomp", "prctl", "userfaultfd", "fanotify_init", "fanotify_mark", "acct", "syslog", "reboot", "vhangup",
           "lsm_set_self_attr", "lsm_get_self_attr", "lsm_list_modules", "statmount", "listmount", "get_mempolicy",
           "mbind", "set_mempolicy", "migrate_pages", "move_pages", "socketpair", "ioctl", "mknodat", "setuid", "capset",
           "prlimit64", "get_robust_list", "sched_setaffinity", "kill", "tgkill", "rt_sigqueueinfo", "setxattr",
           "openat", "openat2", "mmap", "mprotect", "pkey_mprotect", "shmat", "mq_open", "membarrier", "rseq", "setpriority",
           "ioprio_set", "sched_setattr", "sched_setscheduler", "mlockall", "sync", "vmsplice", "splice", "tee",
           "io_setup", "io_submit", "timer_create", "inotify_init1", "epoll_create1", "eventfd2", "signalfd4", "timerfd_create"]


def lookup(prog, spec, byname):
    name, _, arg = spec.partition(":")
    nr = byname[name]
    a = int(arg, 0) if arg else 0
    return nr, verdict(run(prog, nr, args=(a,)))


def cmd_claims():
    prog = kcos_program()
    byname = {v: k for k, v in names().items()}
    bad = 0
    print("README claim -> system calls -> verdict of the installed filter")
    for claim, specs in CLAIMS:
        for s in specs:
            nr, v = lookup(prog, s, byname)
            refused = v.startswith("ERRNO")
            bad += not refused
            print("  %-48s %-22s %4d  %s%s" % (claim, s, nr, v, "" if refused else "   <-- NOT REFUSED"))
    print("claimed-refused calls that the filter lets through: %d" % bad)
    print()
    print("related calls (not all claimed): verdict")
    for s in RELATED:
        nr, v = lookup(prog, s, byname)
        print("  %-26s %4d  %s" % (s, nr, v))


def cmd_docker():
    path = os.path.join(OUT, "filter-release-nobody-dockerdefault.txt")
    progs = [p for p in load_dump(path) if p[0] != 1]
    docker = [p[2] for p in progs if len(p[2]) != len(kcos_program())]
    if not docker:
        print("no Docker filter in the dump")
        return
    docker, kcos, nm = docker[0], kcos_program(), names()
    print("Docker's default filter as installed on this host: %d instructions" % len(docker))
    only_docker, only_kcos, both = [], [], 0
    for nr in sorted(nm):
        if nr > 466:
            continue
        d, k = verdict(run(docker, nr)), verdict(run(kcos, nr))
        if d != "ALLOW" and k == "ALLOW":
            only_docker.append("%s(%d)=%s" % (nm[nr], nr, d))
        elif d == "ALLOW" and k != "ALLOW":
            only_kcos.append("%s(%d)" % (nm[nr], nr))
        elif d != "ALLOW":
            both += 1
    print("(arguments all zero; Docker's filter was built for a container without extra capabilities)")
    print("refused by both: %d" % both)
    print("refused by Docker's default only (%d): %s" % (len(only_docker), " ".join(only_docker)))
    print("refused by kContainerOS only (%d): %s" % (len(only_kcos), " ".join(only_kcos)))


def parse_probe(path):
    rows = []
    for line in open(path):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 4 and re.match(r"(ok|errno):-?\d+$", parts[3]):
            rows.append((parts[0], int(parts[1], 16), int(parts[2], 16), parts[3]))
    return rows


def cmd_compare(init_path, ctrl_path=None):
    prog = kcos_program()
    init = parse_probe(init_path)
    ctrl = {r[0]: r for r in parse_probe(ctrl_path)} if ctrl_path else {}
    codes = {"ERRNO(EPERM)": "errno:1", "ERRNO(ENOSYS)": "errno:38", "ERRNO(EALREADY)": "errno:114"}
    mism = refused = allowed = same = capdiff = control_refused = 0
    print("%-48s %-6s %-16s %-10s %-10s %s" % ("call", "nr", "filter says", "init", "no init", ""))
    for label, x8, a0, res in init:
        nr = x8 & M32  # the kernel takes the low 32 bits of x8 as the number
        v = verdict(run(prog, nr, args=(a0,)))
        c = ctrl.get(label, (None, None, None, "-"))[3]
        note = ""
        if v in codes:
            refused += 1
            if res != codes[v]:
                mism += 1
                note = "MISMATCH: filter says %s" % v
            elif c == res:
                control_refused += 1
                note = "same answer without init (kernel's own)"
        else:
            allowed += 1
            if c == "-":
                note = ""
            elif res == c or (res.startswith("ok") and c.startswith("ok")):
                same += 1
            else:
                capdiff += 1
                note = "let through by the filter; differs from the run without init"
        print("%-48s %-6d %-16s %-10s %-10s %s" % (label[:48], nr, v, res, c, note))
    print()
    print("calls: %d; filter verdict refuse: %d, of which kernel answered otherwise: %d" % (len(init), refused, mism))
    print("refused calls whose control gives the same errno anyway (no evidence either way): %d" % control_refused)
    print("filter verdict allow: %d; same outcome as without init: %d; different outcome: %d" % (allowed, same, capdiff))
    print("RESULT compare: %s" % ("ok" if mism == 0 and init else "PROBLEM"))


def cmd_refused():
    prog = kcos_program()
    print(" ".join(str(nr) for nr in range(0, 1101)
                   if verdict(run(prog, nr)).startswith("ERRNO") and not arg_dependent(prog, nr)))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    fn = globals().get("cmd_" + cmd)
    if not fn:
        sys.exit(__doc__)
    fn(*sys.argv[2:])
