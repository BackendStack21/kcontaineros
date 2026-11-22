#!/usr/bin/env python3
"""Redraw the picture of the binary in the share image, docs/og.png.

    tools/update-og.py BINARY [IMAGE]

The right-hand panel of the image shows every byte of /bin/kcontaineros as
one pixel, coloured as the landing page colours it. This replaces what is
inside the panel's frame with the picture of BINARY and leaves the rest of
the image alone. Run it after tools/update-docs.sh, with the same binary.
Needs nothing but python3.
"""
import math
import struct
import sys
import zlib

ZERO = (0xD9, 0xE0, 0xE7)
INK = (0x10, 0x20, 0x2E)
COLOURS = {
    "code": (0xB7, 0x41, 0x0E),
    "rodata": (0x0C, 0x6B, 0x74),
    "unwind": (0x7F, 0x93, 0xA8),
    "reloc": (0x4E, 0x60, 0x74),
    "data": (0xB7, 0x41, 0x0E),
    "head": INK,
    "pad": (0xC3, 0xCD, 0xD7),
}


def read_png(path):
    """An 8-bit RGB, non-interlaced PNG as (width, height, rows of bytearray)."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    at, idat, header = 8, b"", None
    while at < len(data):
        size, kind = struct.unpack(">I4s", data[at:at + 8])
        body = data[at + 8:at + 8 + size]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        at += 12 + size
    width, height, depth, colour, _, _, interlace = header
    assert (depth, colour, interlace) == (8, 2, 0), "expected 8-bit RGB, not interlaced"
    raw, stride, rows = zlib.decompress(idat), width * 3, []
    before = bytearray(stride)
    for y in range(height):
        kind = raw[y * (stride + 1)]
        row = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            left = row[i - 3] if i >= 3 else 0
            up, corner = before[i], before[i - 3] if i >= 3 else 0
            if kind == 1:
                row[i] = (row[i] + left) & 255
            elif kind == 2:
                row[i] = (row[i] + up) & 255
            elif kind == 3:
                row[i] = (row[i] + (left + up) // 2) & 255
            elif kind == 4:
                p = left + up - corner
                nearest = min((abs(p - left), 0, left), (abs(p - up), 1, up), (abs(p - corner), 2, corner))[2]
                row[i] = (row[i] + nearest) & 255
        rows.append(row)
        before = row
    return width, height, rows


def write_png(path, width, height, rows):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    with open(path, "wb") as out:
        out.write(b"\x89PNG\r\n\x1a\n")
        out.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        out.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        out.write(chunk(b"IEND", b""))


def categories(b):
    """The category of every byte, as the page's parseElf() decides it."""
    n = len(b)
    u16 = lambda o: struct.unpack_from("<H", b, o)[0]
    u32 = lambda o: struct.unpack_from("<I", b, o)[0]
    u64 = lambda o: struct.unpack_from("<Q", b, o)[0]
    assert b[:6] == b"\x7fELF\x02\x01", "not a little-endian ELF64 file"
    phoff, shoff, ehsize = u64(32), u64(40), u16(52)
    phentsize, phnum, shentsize, shnum, shstrndx = u16(54), u16(56), u16(58), u16(60), u16(62)
    regions = [(0, ehsize, "head"), (phoff, phnum * phentsize, "head"), (shoff, shnum * shentsize, "head")]
    relro = None
    for k in range(phnum):
        p = phoff + k * phentsize
        if u32(p) == 0x6474E552:
            relro = (u64(p + 8), u64(p + 8) + u64(p + 32))
    strtab = u64(shoff + shstrndx * shentsize + 24)
    for k in range(1, shnum):
        h = shoff + k * shentsize
        kind, flags, off, size = u32(h + 4), u32(h + 8), u64(h + 24), u64(h + 32)
        if kind in (0, 8) or not size:
            continue
        name = b[strtab + u32(h):b.index(b"\0", strtab + u32(h))]
        if flags & 4:
            cat = "code"
        elif name.startswith(b".eh_frame"):
            cat = "unwind"
        elif not flags & 2:
            cat = "head"
        elif relro and relro[0] <= off < relro[1]:
            cat = "reloc"
        elif kind in (3, 4, 5, 6, 9, 11, 0x6FFFFFF6):
            cat = "reloc"
        elif flags & 1:
            cat = "data"
        else:
            cat = "rodata"
        regions.append((off, size, cat))
    out, at = ["pad"] * n, 0
    for start, size, cat in sorted(regions, key=lambda r: (r[0], -r[1])):
        end = min(n, start + size)
        for j in range(max(start, at), end):
            out[j] = cat
        at = max(at, end)
    return out


def main():
    binary = open(sys.argv[1], "rb").read()
    image = sys.argv[2] if len(sys.argv) > 2 else "docs/og.png"
    width, height, rows = read_png(image)
    pixel = lambda x, y: tuple(rows[y][x * 3:x * 3 + 3])

    # The panel is the framed square in the right half: find the frame's
    # inner edges along the middle row and the panel's middle column.
    mid = height // 2
    frame = [x for x in range(width // 2, width) if pixel(x, mid) == INK]
    left, right = frame[0], frame[-1]
    while pixel(left, mid) == INK:
        left += 1
    while pixel(right, mid) == INK:
        right -= 1
    centre = (left + right) // 2
    edge = [y for y in range(height) if pixel(centre, y) == INK]
    top, bottom = edge[0], edge[-1]
    while pixel(centre, top) == INK:
        top += 1
    while pixel(centre, bottom) == INK:
        bottom -= 1

    n = len(binary)
    side = math.ceil(math.sqrt(n))
    tall = math.ceil(n / side)
    cats = categories(binary)
    for y in range(top, bottom + 1):
        for x in range(left, right + 1):
            j = (y - top) * tall // (bottom - top + 1) * side + (x - left) * side // (right - left + 1)
            colour = ZERO
            if j < n and binary[j]:
                to, t = COLOURS[cats[j]], 0.3 + 0.7 * binary[j] / 255
                colour = tuple(int(z + (c - z) * t) for z, c in zip(ZERO, to))
            rows[y][x * 3:x * 3 + 3] = bytes(colour)
    write_png(image, width, height, rows)
    print(f"{image}: panel {right - left + 1}x{bottom - top + 1} redrawn from {n} bytes")


if __name__ == "__main__":
    main()
