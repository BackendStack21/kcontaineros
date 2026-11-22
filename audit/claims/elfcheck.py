#!/usr/bin/env python3
"""Read hardening properties off an aarch64 ELF file, independently of test/elf.py.
  elfcheck.py FILE          type= interp= needed= execstack= wx= relro=
  elfcheck.py --notes FILE  eh_frame= bti=
"""
import struct, sys
notes = sys.argv[1] == "--notes"
d = open(sys.argv[-1], "rb").read()
assert d[:4] == b"\x7fELF" and d[4] == 2 and d[5] == 1
e_type, e_machine = struct.unpack_from("<HH", d, 16)
e_phoff, e_shoff = struct.unpack_from("<QQ", d, 32)
e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHHHH", d, 54)
ph = [struct.unpack_from("<IIQQQQQQ", d, e_phoff + i * e_phentsize) for i in range(e_phnum)]  # type flags off vaddr paddr filesz memsz align
PT_LOAD, PT_DYNAMIC, PT_INTERP, PT_NOTE, PT_GNU_STACK, PT_GNU_RELRO = 1, 2, 3, 4, 0x6474e551, 0x6474e552
if not notes:
    needed = 0
    for p in ph:
        if p[0] == PT_DYNAMIC:
            for o in range(p[2], p[2] + p[5], 16):
                tag, val = struct.unpack_from("<QQ", d, o)
                if tag == 0: break
                if tag == 1: needed += 1
    stack = [p for p in ph if p[0] == PT_GNU_STACK]
    print("type=%s interp=%s needed=%d execstack=%s wx=%s relro=%s" % (
        {2: "ET_EXEC", 3: "ET_DYN"}.get(e_type, e_type),
        "yes" if any(p[0] == PT_INTERP for p in ph) else "no", needed,
        "no" if stack and not stack[0][1] & 1 else "yes",
        "yes" if any(p[0] == PT_LOAD and p[1] & 3 == 3 for p in ph) else "no",
        "yes" if any(p[0] == PT_GNU_RELRO for p in ph) else "no"))
else:
    sh = [struct.unpack_from("<IIQQQQIIQQ", d, e_shoff + i * e_shentsize) for i in range(e_shnum)]
    strtab = sh[e_shstrndx][4] if e_shnum else 0
    names = [d[strtab + s[0]:d.index(b"\0", strtab + s[0])].decode() for s in sh]
    # GNU property note: NT_GNU_PROPERTY_TYPE_0 (5) with GNU_PROPERTY_AARCH64_FEATURE_1_AND (0xc0000000)
    bti = False
    for p in ph:
        if p[0] == PT_NOTE:
            blob = d[p[2]:p[2] + p[5]]
            bti |= struct.pack("<I", 0xc0000000) in blob
    print("eh_frame=%s bti=%s" % ("yes" if ".eh_frame" in names else "no", "yes" if bti else "no"))
