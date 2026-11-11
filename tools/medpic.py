#!/usr/bin/env python3
"""Half-height 4-shade versions of the Help pictures for ST medium (640x200,
two bitplanes, pixels twice as tall as wide).  Every two picture rows become
one row; the shade is the mean brightness of the two.

usage: tools/medpic.py bmp <keyboard.bmp> <out.bin> [preview.png]
       tools/medpic.py pbm <picture.pbm> <out.bin> [preview.png]
       tools/medpic.py pgm <logo-med.pgm> <out.bin> [preview.png]

A PGM (8-bit grey) is taken as already half height (tools/logo.sh renders
assets/logo-med.pgm from the PDF that way).

Output: rows of ST medium screen words, 16 pixels = plane 0 word + plane 1
word, width rounded up to 16 pixels (512 for the keyboard, 448 for the logo).
Colour index 0 = white .. 3 = black (main.s sets the palette to match).
"""
import struct
import sys
import zlib


def read_bmp(path):
    data = open(path, 'rb').read()
    if data[:2] != b'BM':
        sys.exit('not a BMP')
    off = struct.unpack_from('<I', data, 10)[0]
    w, h = struct.unpack_from('<ii', data, 18)
    if struct.unpack_from('<H', data, 28)[0] != 24:
        sys.exit('need a 24-bit BMP')
    stride = (w * 3 + 3) & ~3
    rows = []
    for y in range(abs(h)):
        sy = abs(h) - 1 - y if h > 0 else y
        base = off + sy * stride
        rows.append([(0.299 * data[base + 3 * x + 2] + 0.587 * data[base + 3 * x + 1]
                      + 0.114 * data[base + 3 * x]) / 255 for x in range(w)])
    return w, rows


def read_pbm(path):
    data = open(path, 'rb').read()
    head = [t for line in data.split(b'\n', 3)[:3] if not line.startswith(b'#')
            for t in line.split()]
    i = 0
    while len(head) < 3:                          # skip comment lines
        i += 1
        head = [t for line in data.split(b'\n', 3 + i)[:3 + i]
                if not line.startswith(b'#') for t in line.split()]
    if head[0] != b'P4':
        sys.exit('need a raw PBM (P4)')
    w, h = int(head[1]), int(head[2])
    bpr = (w + 7) // 8
    body = data[-bpr * h:]
    rows = []
    for y in range(h):
        r = body[y * bpr:(y + 1) * bpr]
        rows.append([0.0 if r[x >> 3] & (0x80 >> (x & 7)) else 1.0 for x in range(w)])
    return w, rows


def read_pgm(path):
    data = open(path, 'rb').read()
    head = []
    for line in data.split(b'\n'):
        if not line.startswith(b'#'):
            head += line.split()
        if len(head) >= 4:
            break
    if head[0] != b'P5' or int(head[3]) > 255:
        sys.exit('need an 8-bit raw PGM (P5)')
    w, h = int(head[1]), int(head[2])
    body = data[-w * h:]
    return w, [[body[y * w + x] / 255 for x in range(w)] for y in range(h)]


def quantize(rows):
    return [[3 - min(3, int(v * 3 + 0.5)) for v in r] for r in rows]


def shades(w, rows):
    """bright (1.0 = white) rows -> half-height rows of colour index 0..3"""
    if len(rows) & 1:
        rows = rows + [[1.0] * w]
    out = []
    for y in range(0, len(rows), 2):
        out.append([3 - min(3, int((rows[y][x] + rows[y + 1][x]) / 2 * 3 + 0.5))
                    for x in range(w)])
    return out


def to_medium(w, rows):
    w16 = (w + 15) // 16 * 16
    data = bytearray()
    for r in rows:
        r = r + [0] * (w16 - w)
        for g in range(0, w16, 16):
            p0 = p1 = 0
            for x in range(16):
                c = r[g + x]
                p0 = p0 << 1 | (c & 1)
                p1 = p1 << 1 | (c >> 1)
            data += struct.pack('>HH', p0, p1)
    return w16, data


def write_png(path, rows):
    """preview: each pixel 1 wide, 2 tall (the shape on a medium screen)"""
    grey = [255, 170, 85, 0]
    raw = bytearray()
    for r in rows:
        line = bytes([0] + [grey[c] for c in r])
        raw += line + line
    w, h = len(rows[0]), 2 * len(rows)

    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 0, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b''))


def main():
    kind, src, out = sys.argv[1:4]
    w, rows = {'bmp': read_bmp, 'pbm': read_pbm, 'pgm': read_pgm}[kind](src)
    if kind == 'bmp' and w < 512:                 # keyboard: pad to 512 like kbpic.py
        rows = [r + [1.0] * (512 - w) for r in rows]
        w = 512
    half = quantize(rows) if kind == 'pgm' else shades(w, rows)
    w16, data = to_medium(w, half)
    open(out, 'wb').write(data)
    if len(sys.argv) > 4:
        write_png(sys.argv[4], half)
    print('%s: %dx%d, %d bytes' % (out, w16, len(half), len(data)))


if __name__ == '__main__':
    main()
