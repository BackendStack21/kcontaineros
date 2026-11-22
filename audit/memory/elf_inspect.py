#!/usr/bin/env python3
"""Static inspection of the kContainerOS release ELF (track: memory, part f).

usage: elf_inspect.py FILE

Prints program headers, dynamic entries, relocation types and where they
land, how much of the relocated area PT_GNU_RELRO covers after the page
rounding kcos_start does, notes (BTI/PAC), leftover strings that could leak
the build host, and a list of CHECK lines (ok / FAIL).
"""
import re
import struct
import sys

data = open(sys.argv[1], "rb").read()
PAGE = 4096
checks = []


def check(name, ok, detail=""):
    checks.append((name, ok, detail))


assert data[:4] == b"\x7fELF"
ei_class, ei_data = data[4], data[5]
e_type, e_machine = struct.unpack_from("<HH", data, 0x10)
e_entry, e_phoff, e_shoff = struct.unpack_from("<QQQ", data, 0x18)
e_flags, e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<IHHHHHH", data, 0x30)
print("size=%d class=%d data=%d type=%d machine=%d entry=%#x phnum=%d shnum=%d" % (
    len(data), ei_class, ei_data, e_type, e_machine, e_entry, e_phnum, e_shnum))
check("ET_DYN (PIE)", e_type == 3)
check("EM_AARCH64", e_machine == 183)

PT = {0: "NULL", 1: "LOAD", 2: "DYNAMIC", 3: "INTERP", 4: "NOTE", 6: "PHDR", 7: "TLS",
      0x6474E550: "GNU_EH_FRAME", 0x6474E551: "GNU_STACK", 0x6474E552: "GNU_RELRO",
      0x6474E553: "GNU_PROPERTY"}
phdrs = []
print("\nprogram headers:")
for i in range(e_phnum):
    p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = struct.unpack_from(
        "<IIQQQQQQ", data, e_phoff + i * e_phentsize)
    phdrs.append((p_type, p_flags, p_offset, p_vaddr, p_filesz, p_memsz, p_align))
    fl = "".join(c if p_flags & b else "-" for c, b in (("R", 4), ("W", 2), ("X", 1)))
    print("  %-13s %s off=%#07x vaddr=%#07x filesz=%#07x memsz=%#07x align=%#x" % (
        PT.get(p_type, hex(p_type)), fl, p_offset, p_vaddr, p_filesz, p_memsz, p_align))

types = [p[0] for p in phdrs]
check("no PT_INTERP", 3 not in types)
check("no segment is W+X", not any(p[1] & 3 == 3 for p in phdrs))
stack = [p for p in phdrs if p[0] == 0x6474E551]
check("PT_GNU_STACK present and not executable", bool(stack) and not stack[0][1] & 1,
      "flags=%s" % (stack[0][1] if stack else "missing"))
relro = [p for p in phdrs if p[0] == 0x6474E552]
check("PT_GNU_RELRO present", bool(relro))
check("no PT_TLS (nothing initialises TLS)", 7 not in types)


def off(vaddr):
    for t, fl, o, va, fs, ms, al in phdrs:
        if t == 1 and va <= vaddr < va + fs:
            return o + vaddr - va
    return None


def seg(vaddr):
    for t, fl, o, va, fs, ms, al in phdrs:
        if t == 1 and va <= vaddr < va + ms:
            return (fl, va, ms)
    return None


# dynamic section
dyn = [p for p in phdrs if p[0] == 2]
DT = {1: "NEEDED", 4: "HASH", 5: "STRTAB", 6: "SYMTAB", 7: "RELA", 8: "RELASZ", 9: "RELAENT",
      10: "STRSZ", 11: "SYMENT", 12: "INIT", 13: "FINI", 17: "REL", 18: "RELSZ", 20: "PLTREL",
      21: "DEBUG", 22: "TEXTREL", 23: "JMPREL", 2: "PLTRELSZ", 24: "BIND_NOW", 25: "INIT_ARRAY",
      26: "FINI_ARRAY", 27: "INIT_ARRAYSZ", 28: "FINI_ARRAYSZ", 30: "FLAGS", 35: "RELRSZ",
      36: "RELR", 37: "RELRENT", 0x6FFFFFFB: "FLAGS_1", 0x6FFFFFF9: "RELACOUNT",
      0x6FFFFEF5: "GNU_HASH"}
d = {}
print("\ndynamic:")
if dyn:
    o = dyn[0][2]
    while True:
        tag, val = struct.unpack_from("<QQ", data, o)
        if tag == 0:
            break
        d[tag] = val
        print("  %-12s %#x" % (DT.get(tag, hex(tag)), val))
        o += 16
check("no DT_NEEDED", 1 not in d)
check("no DT_TEXTREL", 22 not in d and not d.get(30, 0) & 4)
# kcos_start only processes DT_RELA; anything else would be silently skipped
for tag in (17, 23, 36, 25, 26, 12, 13):
    check("no DT_%s (kcos_start would ignore it)" % DT[tag], tag not in d or d.get({25: 27, 26: 28}.get(tag, tag), 1) == 0)

rela, relasz = d.get(7, 0), d.get(8, 0)
kinds = {}
outside = 0
not_ro = 0
rr = relro[0] if relro else None
if rr:
    r_start, r_end = rr[3], rr[3] + rr[5]
    nxt = min([p[3] for p in phdrs if p[0] == 1 and p[3] > r_start] or [None])
    # the same rounding kcos_start does (base is page aligned, so base-independent)
    prot_start = r_start & ~(PAGE - 1)
    prot_stop = (r_end + PAGE - 1) & ~(PAGE - 1)
    if nxt is not None and prot_stop > nxt:
        prot_stop = r_end & ~(PAGE - 1)
    print("\nRELRO: vaddr %#x..%#x; mprotect(PROT_READ) will cover %#x..%#x with 4 KiB pages; next PT_LOAD at %s" % (
        r_start, r_end, prot_start, prot_stop, hex(nxt) if nxt is not None else None))
    for ps in (16384, 65536):
        a = r_start & ~(ps - 1)
        b = (r_end + ps - 1) & ~(ps - 1)
        if nxt is not None and b > nxt:
            b = r_end & ~(ps - 1)
        print("       with %d KiB pages: %#x..%#x (%s)" % (ps // 1024, a, b, "nothing protected" if b <= a else "ok"))
        # mprotect would also need the start to be the start of a mapping-aligned page
targets = []
if rela:
    o = off(rela)
    for k in range(relasz // 24):
        r_off, r_info, r_add = struct.unpack_from("<QQq", data, o + k * 24)
        t = r_info & 0xFFFFFFFF
        kinds[t] = kinds.get(t, 0) + 1
        targets.append(r_off)
        s = seg(r_off)
        if s is None:
            outside += 1
        if rr and not (prot_start <= r_off and r_off + 8 <= prot_stop):
            not_ro += 1
        if seg(r_add) is None:
            outside += 1
print("relocations: %d, by type %s" % (len(targets), {k: v for k, v in kinds.items()}))
check("every relocation is R_AARCH64_RELATIVE (1027): others are skipped silently", set(kinds) <= {1027}, str(kinds))
check("every relocation offset and addend lies inside a PT_LOAD", outside == 0, "outside=%d" % outside)
check("every relocated word ends up inside the range made read-only", not_ro == 0, "not covered=%d" % not_ro)
if targets:
    print("relocation targets span %#x..%#x" % (min(targets), max(targets) + 8))

# writable data that stays writable
for t, fl, o, va, fs, ms, al in phdrs:
    if t == 1 and fl & 2:
        if rr:
            lo, hi = max(va, prot_stop), va + ms
            print("writable after start: %#x..%#x (%d bytes of .data/.bss)" % (lo, hi, max(0, hi - lo)))

# sections (stripped?)
print("\nsections:")
names = []
if e_shnum:
    sh = [struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize) for i in range(e_shnum)]
    stro = sh[e_shstrndx][4]
    for s in sh:
        n = data[stro + s[0]:data.index(b"\0", stro + s[0])].decode()
        names.append(n)
        if n:
            print("  %-20s type=%-10d addr=%#07x size=%d" % (n, s[1], s[3], s[5]))
check("no .symtab / .debug sections", not any(n == ".symtab" or n.startswith(".debug") for n in names))
check("no .comment section", ".comment" not in names)

# notes
print("\nnotes:")
bti = pac = False
for t, fl, o, va, fs, ms, al in phdrs:
    if t in (4, 0x6474E553):
        p = o
        while p < o + fs:
            namesz, descsz, ntype = struct.unpack_from("<III", data, p)
            name = data[p + 12:p + 12 + namesz]
            desc = data[p + 12 + ((namesz + 3) & ~3):][:descsz]
            print("  note name=%r type=%d desc=%s" % (name, ntype, desc.hex()))
            if ntype == 5 and name.startswith(b"GNU") and len(desc) >= 12:
                pt, psz, pv = struct.unpack_from("<III", desc, 0)
                if pt == 0xC0000000:
                    bti, pac = bool(pv & 1), bool(pv & 2)
            p += 12 + ((namesz + 3) & ~3) + ((descsz + 3) & ~3)
print("  BTI=%s PAC=%s (README says: neither)" % (bti, pac))

# code: does the text use paciasp / bti (hint) or a stack-protector guard?
text = [p for p in phdrs if p[0] == 1 and p[1] & 1]
if text:
    t = text[0]
    code = data[t[2]:t[2] + t[4]]
    words = struct.unpack_from("<%dI" % (len(code) // 4), code)
    print("  instructions: paciasp=%d bti=%d svc0=%d" % (
        words.count(0xD503233F), sum(1 for w in words if w in (0xD503245F, 0xD503249F, 0xD50324DF)),
        words.count(0xD4000001)))

# strings that could leak the build host
print("\nstrings of interest:")
strings = re.findall(rb"[\x20-\x7e]{6,}", data)
leaks = [s for s in strings if re.search(rb"/(home|Users|root|src|rustc|usr|tmp|cargo|build)/|\.rs\b|rustc|GCC:|clang|Linker|LLD", s)]
for s in leaks[:40]:
    print("  " + s.decode())
print("  (%d strings >= 6 chars, %d look like paths or toolchain names)" % (len(strings), len(leaks)))
check("no absolute build-host path (/home, /Users, /root, /src) in the binary",
      not any(re.search(rb"/(home|Users|root|src)/", s) for s in strings))

print("\nchecks:")
bad = 0
for name, ok, detail in checks:
    print("  %-4s %s%s" % ("ok" if ok else "FAIL", name, (" [" + detail + "]") if detail and not ok else ""))
    bad += not ok
print("%d checks, %d failed" % (len(checks), bad))
