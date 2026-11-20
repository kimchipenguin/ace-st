#!/usr/bin/env python3
"""flagtab.py listing out.i: the GETF sites (.gf_nnnnnn labels) of the
kernel, from a vasm -L listing of gem/glue.s, as offsets from _kernel_start
(dc.l), plus flagcnt.  ACEGEM patches them to move ccr on 68010+."""
import re
import sys

lst, out = sys.argv[1], sys.argv[2]
offs = []
start = None
for line in open(lst, errors='replace'):
    m = re.search(r'(?:^|\s)(\S+) LAB \((0x[0-9a-f]+)\)\s.*sec=text', line)
    if not m:
        continue
    name, val = m.group(1), int(m.group(2), 16)
    if name == '_kernel_start':
        start = val
    elif re.search(r'\.gf_\d+$', name):
        offs.append(val)
if start is None:
    sys.exit('flagtab.py: no _kernel_start in ' + lst)
offs = sorted(set(o - start for o in offs))
with open(out, 'w') as fh:
    fh.write('; made by tools/flagtab.py: GETF sites (offsets from _kernel_start)\n')
    fh.write('flagcnt equ %d\n' % len(offs))
    for i in range(0, len(offs), 8):
        fh.write('        dc.l    ' + ','.join('$%x' % o for o in offs[i:i + 8]) + '\n')
print('flagtab.py: %d sites' % len(offs))
