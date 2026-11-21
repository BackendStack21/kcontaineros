#!/usr/bin/env python3
"""Describe the hardening-relevant properties of an ELF file in one line."""
import struct
import sys

data = open(sys.argv[1], "rb").read()
e_type = struct.unpack_from("<H", data, 0x10)[0]
phoff = struct.unpack_from("<Q", data, 0x20)[0]
phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
PT_INTERP, PT_GNU_STACK, PT_GNU_RELRO = 3, 0x6474E551, 0x6474E552
kinds = {}
writable_and_executable = False
for i in range(phnum):
    p_type, p_flags = struct.unpack_from("<II", data, phoff + i * phentsize)
    kinds[p_type] = p_flags
    writable_and_executable |= p_flags & 3 == 3
yes = lambda b: "yes" if b else "no"
print("type=%s interp=%s execstack=%s wx=%s relro=%s" % (
    {2: "exec", 3: "pie"}.get(e_type, e_type),
    yes(PT_INTERP in kinds),
    yes(kinds.get(PT_GNU_STACK, 1) & 1),
    yes(writable_and_executable),
    yes(PT_GNU_RELRO in kinds),
))
