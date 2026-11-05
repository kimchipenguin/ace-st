#!/usr/bin/env python3
"""Sampling profile of ACE-ST: map the 68000 PCs Hatari printed ("Next PC")
to the labels of a vasm listing.

  ~/Develop/vasm-src/vasm/vasmm68k_mot -Ftos -m68000 -Isrc -o /dev/null -L ace.lst src/main.s
  test/run.sh samp test/scripts/gsample.txt
  test/pcprof.py ace.lst test/shots/samp.log [text start, default 0x125f8 = TOS 1.04 rig]

Also reports the share of samples in the NEXT dispatch sequence."""
import bisect, collections, re, sys

lst = open(sys.argv[1], errors='replace').read()
base = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x125f8
labs = sorted((int(m.group(2), 16), m.group(1)) for m in re.finditer(
    r'^(\S+) LAB \((0x[0-9a-f]+)\).*sec=text', lst, re.M)
    if not m.group(1).startswith('.'))
keys = [a for a, _ in labs]
prg = open('ACE.PRG', 'rb').read()
text = prg[28:28 + int.from_bytes(prg[2:6], 'big')]
pat = bytes.fromhex('70001018d04030330000' '4ef40000')
starts = set()
i = text.find(pat)
while i >= 0:
    starts.add(i)
    i = text.find(pat, i + 1)
c = collections.Counter()
n = nxt = out = 0
for l in open(sys.argv[2]):
    if not l.startswith('Next PC:'):
        continue
    pc = int(l.split()[2], 16) - base
    n += 1
    if pc < 0 or pc >= len(text):
        out += 1
        continue
    if any(pc - o in starts for o in (0, 2, 4, 6, 10)):
        nxt += 1
    c[labs[bisect.bisect_right(keys, pc) - 1][1]] += 1
print('%d samples, %.1f%% outside ACE-ST code (TOS, ISRs), %.1f%% in NEXT dispatch'
      % (n, 100 * out / n, 100 * nxt / n))
for k, v in c.most_common(30):
    print('%5.1f%% %s' % (100 * v / n, k))
