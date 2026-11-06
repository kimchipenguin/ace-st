#!/usr/bin/env python3
"""Convert EightyOne's Jupiter Ace keyboard picture (24-bit BMP) to a 1-bit
ST high bitmap for the Help key: 512 pixels (64 bytes) wide, 1 = black.

usage: tools/kbpic.py <in.bmp> <out.bin> [preview.png]

The picture is keyboardJupiterAce.bmp from EightyOne (Michael D Wynne,
GPL v2 or later); see assets/README.md.
"""
import struct
import sys
import zlib

WIDTH = 512           # bitmap width in pixels (picture is 505)
THRESHOLD = 128       # luminance below this is black


def read_bmp(path):
    data = open(path, 'rb').read()
    if data[:2] != b'BM':
        sys.exit('not a BMP')
    off = struct.unpack_from('<I', data, 10)[0]
    w, h = struct.unpack_from('<ii', data, 18)
    bpp = struct.unpack_from('<H', data, 28)[0]
    if bpp != 24:
        sys.exit('need a 24-bit BMP')
    stride = (w * 3 + 3) & ~3
    rows = []
    for y in range(abs(h)):
        sy = abs(h) - 1 - y if h > 0 else y        # BMP rows run bottom-up
        base = off + sy * stride
        row = []
        for x in range(w):
            b, g, r = data[base + 3 * x:base + 3 * x + 3]
            row.append(0.299 * r + 0.587 * g + 0.114 * b < THRESHOLD)
        rows.append(row)
    return w, abs(h), rows


def write_png(path, rows):
    raw = b''.join(b'\0' + bytes(0 if p else 255 for p in r) for r in rows)
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    ihdr = struct.pack('>IIBBBBB', len(rows[0]), len(rows), 8, 0, 0, 0, 0)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) +
                           chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def main():
    w, h, rows = read_bmp(sys.argv[1])
    if w > WIDTH:
        sys.exit('picture wider than %d' % WIDTH)
    rows = [r + [False] * (WIDTH - w) for r in rows]
    out = bytearray()
    for r in rows:
        for x in range(0, WIDTH, 8):
            byte = 0
            for p in r[x:x + 8]:
                byte = (byte << 1) | p
            out.append(byte)
    open(sys.argv[2], 'wb').write(out)
    if len(sys.argv) > 3:
        write_png(sys.argv[3], rows)
    print('%s: %dx%d -> %d bytes' % (sys.argv[2], WIDTH, h, len(out)))


main()
