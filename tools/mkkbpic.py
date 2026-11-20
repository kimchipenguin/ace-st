#!/usr/bin/env python3
"""The Jupiter Ace keyboard picture for ACEGEM's keyboard window.

usage: tools/mkkbpic.py assets/keyboardJupiterAce.bmp gem/build/kbpic.h

EightyOne's picture (24-bit BMP, GPL 2, see assets/README.md) as words
for vrt_cpyfm, 1 = dark (the keys), and the 40 key faces (the large dark
areas) in the order of the picture: 1-0, Q-P, A-ENTER, SHIFT-SPACE.
"""
import struct
import sys


def read_bmp(path):
    d = open(path, 'rb').read()
    if d[:2] != b'BM':
        sys.exit('%s: not a BMP' % path)
    off = struct.unpack_from('<I', d, 10)[0]
    w, h = struct.unpack_from('<ii', d, 18)
    bpp = struct.unpack_from('<H', d, 28)[0]
    if bpp != 24:
        sys.exit('%s: 24-bit BMP expected' % path)
    stride = (w * 3 + 3) & ~3
    rows = []
    for y in range(abs(h)):
        sy = abs(h) - 1 - y if h > 0 else y
        p = off + sy * stride
        row = []
        for x in range(w):
            b, g, r = d[p + 3 * x:p + 3 * x + 3]
            row.append(1 if (r * 30 + g * 59 + b * 11) < 128 * 100 else 0)
        rows.append(row)
    return w, abs(h), rows


def find_keys(w, h, rows):
    """the dark areas larger than 15 x 15: the key faces"""
    seen = [[0] * w for _ in range(h)]
    boxes = []
    for y in range(h):
        for x in range(w):
            if not rows[y][x] or seen[y][x]:
                continue
            stack = [(x, y)]
            seen[y][x] = 1
            x0 = x1 = x
            y0 = y1 = y
            while stack:
                a, b = stack.pop()
                x0, x1, y0, y1 = min(x0, a), max(x1, a), min(y0, b), max(y1, b)
                for c, e in ((a + 1, b), (a - 1, b), (a, b + 1), (a, b - 1)):
                    if 0 <= c < w and 0 <= e < h and rows[e][c] and not seen[e][c]:
                        seen[e][c] = 1
                        stack.append((c, e))
            if x1 - x0 > 15 and y1 - y0 > 15:
                boxes.append((x0, y0, x1 - x0 + 1, y1 - y0 + 1))
    if len(boxes) != 40:
        sys.exit('found %d keys, not 40' % len(boxes))
    # four rows of ten: by the middle of the key, top to bottom, then left
    # to right
    boxes.sort(key=lambda b: b[1] + b[3] // 2)
    keys = []
    for r in range(4):
        keys += sorted(boxes[r * 10:r * 10 + 10])
    return keys


def write_header(path, w, h, rows, keys):
    words = (w + 15) // 16
    out = ['/* made by tools/mkkbpic.py from assets/keyboardJupiterAce.bmp: the',
           '   Jupiter Ace keyboard from EightyOne (GPL 2), 1 = dark (the keys) */',
           '#define KB_W %d' % w, '#define KB_H %d' % h,
           '#define KB_WORDS %d' % words, '',
           'static const unsigned short kb_bits[KB_WORDS * KB_H] = {']
    for row in rows:
        vals = []
        for x in range(0, words * 16, 16):
            v = 0
            for i in range(16):
                v = v << 1 | (row[x + i] if x + i < w else 0)
            vals.append('0x%04X' % v)
        out.append('\t' + ','.join(vals) + ',')
    out.append('};')
    out.append('')
    out.append('/* the key faces (x, y, w, h): 1-0, Q-P, A-ENTER, SHIFT-SPACE */')
    out.append('static const short kb_face[40][4] = {')
    for r in range(4):
        out.append('\t' + ' '.join('{ %d, %d, %d, %d },' % k
                                    for k in keys[r * 10:r * 10 + 10]))
    out.append('};')
    open(path, 'w').write('\n'.join(out) + '\n')


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    w, h, rows = read_bmp(sys.argv[1])
    write_header(sys.argv[2], w, h, rows, find_keys(w, h, rows))


main()
