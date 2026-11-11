#!/usr/bin/env python3
"""
ACE-ST - build the resource file ACE.RSC (settings dialog, alert texts) and
the object numbers for the assembler, src/rsc.i

    tools/mkrsc.py <out.rsc> <out.i>     write both files (make rsc)
    tools/mkrsc.py --dump <file.rsc>     list what is in a resource file

ACE.RSC can be changed with a resource editor (texts, positions, sizes):
keep the tree, the order of the objects and the order of the free strings,
or update src/rsc.i to match.  Plain AES objects only (TOS 1.0 and later).
The joystick buttons need room for 3 characters (main.s writes the key
names into them).

Coordinates are in characters; a value can also be given as (chars,
pixels), stored as pixels * 256 + chars like resource editors do.
The file is a classic GEM resource file: header, strings, free string
table, TEDINFOs, objects, tree table.  All words big-endian.
(The writer is the one of the Pong and Daleks projects.)
GPL v2 or later.
"""

import struct
import sys

G_BOX, G_TEXT, G_BOXTEXT, G_IMAGE, G_USERDEF, G_IBOX, G_BUTTON, \
    G_BOXCHAR, G_STRING, G_FTEXT, G_FBOXTEXT, G_ICON, G_TITLE = range(20, 33)

NONE = 0x0000
SELECTABLE, DEFAULT, EXIT, EDITABLE, RBUTTON, LASTOB, TOUCHEXIT = \
    0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040
NORMAL, SELECTED, DISABLED, OUTLINED, SHADOWED = 0x00, 0x01, 0x08, 0x10, 0x20

TEXT_TYPES = (G_BUTTON, G_STRING, G_TITLE)
TED_TYPES = (G_TEXT, G_BOXTEXT, G_FTEXT, G_FBOXTEXT)
IBM, TE_LEFT, TE_CNTR = 3, 0, 2


def ted(text, just=TE_LEFT, color=0x1180, thickness=-1):
    """TEDINFO for G_TEXT/G_BOXTEXT; the text area is as long as text."""
    return dict(text=text, just=just, color=color, thickness=thickness)


def obj(name, type_, flags, state, spec, x, y, w, h, children=()):
    return dict(name=name, type=type_, flags=flags, state=state, spec=spec,
                x=x, y=y, w=w, h=h, children=list(children))


def string(name, text, x, y, w=None):
    return obj(name, G_STRING, NONE, NORMAL, text, x, y, w or len(text), 1)


def button(name, text, x, y, w, flags=SELECTABLE | EXIT, state=NORMAL):
    return obj(name, G_BUTTON, flags, state, text, x, y, w, 1)


# ---------------------------------------------------------------- dialog

def settings_tree():
    """Undo: the settings dialog (like the ZX81 Emulator's).  Shortcuts
    (main.s): 1-4 RAM, cursor keys + Insert joystick, T S R Q L W,
    Return / Undo Continue."""
    ram = [button('D_RAM%d' % (i + 1), t, 6 * i, 0, 5, SELECTABLE | RBUTTON)
           for i, t in enumerate(('3K', '19K', '35K', '51K'))]
    # joystick: up, down, left, right, fire (fire in the middle)
    def joy(name, text, x, y):
        return button(name, text, x, y, 5, SELECTABLE | TOUCHEXIT)
    return obj('DIALOG', G_BOX, NONE, OUTLINED, 0x00021100, 0, 0, 52, 17, [
        obj('D_TITLE', G_BOXTEXT, NONE, NORMAL,
            ted('ACE-ST Options', TE_CNTR, 0x1121, -1), 1, 1, 50, 1),
        string(None, 'RAM', 2, 3),
        obj('D_RAMBOX', G_IBOX, NONE, NORMAL, 0, 10, 3, 23, 1, ram),
        string(None, 'Joystick', 2, 6),
        string(None, '\x01', 19, 5),
        joy('D_JUP', ' 7 ', 17, 6),
        string(None, '\x04', 9, 8),
        joy('D_JLEFT', ' 5 ', 11, 8),
        joy('D_JFIRE', ' 0 ', 17, 8),
        joy('D_JRIGHT', ' 8 ', 23, 8),
        string(None, '\x03', 29, 8),
        joy('D_JDOWN', ' 6 ', 17, 10),
        string(None, '\x02', 19, 11),
        string('D_HINT', 'Click a box, then press a key', 2, 13, 31),
        button('D_TAPE', 'Load Tape...', 34, 3, 17),
        button('D_SNAP', 'Load Snapshot...', 34, 5, 17),
        button('D_RESET', 'Reset Ace', 34, 8, 17),
        button('D_QUIT', 'Quit Emulator', 34, 10, 17),
        button('D_LOADP', 'Load Parameters', 2, 15, 15),
        button('D_SAVEP', 'Save Parameters', 18, 15, 15),
        button('D_CONT', 'Continue', 34, 15, 17, SELECTABLE | EXIT | DEFAULT),
    ])


# ---------------------------------------------------------------- free strings

FREE_STRINGS = [
    ('AL_RAM', '[2][The new RAM size needs|a reset of the Ace.][Reset|Cancel]'),
    ('AL_NOSNAP', '[1][This is not a Jupiter Ace|snapshot (.ace).][ OK ]'),
    ('AL_NOFILE', '[1][The file cannot be read.][ OK ]'),
    ('AL_NOMEM', '[1][Not enough memory.][ OK ]'),
    ('AL_INFLOAD', '[1][ACE.INF cannot be read.][ OK ]'),
    ('AL_INFSAVE', '[1][ACE.INF cannot be saved.][ OK ]'),
    ('FS_PRESS', 'Press a key  (Undo: cancel)'),   # D_HINT while waiting
]

TREES = [settings_tree()]

# ---------------------------------------------------------------- writer

def flatten(root):
    """Objects of a tree in resource order (depth first), with links."""
    out = []

    def add(o):
        i = len(out)
        out.append(o)
        o['next'] = o['head'] = o['tail'] = -1
        prev = None
        for c in o['children']:
            j = add(c)
            if prev is None:
                o['head'] = j
            else:
                out[prev]['next'] = j
            prev = j
            out[j]['_parent'] = i
        if prev is not None:
            o['tail'] = prev
            out[prev]['next'] = i
        return i

    add(root)
    root['next'] = -1
    out[-1]['flags'] |= LASTOB
    return out


def coord(v):
    if isinstance(v, tuple):
        chars, pixels = v
        return (pixels & 0xFF) << 8 | (chars & 0xFF)
    return v & 0xFFFF


class Strings:
    def __init__(self):
        self.data = bytearray()
        self.where = {}

    def add(self, s):
        b = s.encode('latin-1') + b'\0'
        off = len(self.data)
        self.data += b
        return off


def build():
    hdr = 36
    strings = Strings()
    trees = [flatten(t) for t in TREES]

    # strings of the objects and TEDINFOs, then the free strings
    teds = []
    for objs in trees:
        for o in objs:
            if o['type'] in TEXT_TYPES:
                o['_str'] = strings.add(o['spec'])
            elif o['type'] in TED_TYPES:
                t = dict(o['spec'])
                t['_text'] = strings.add(t['text'])
                t['_empty'] = strings.add('')
                o['_ted'] = len(teds)
                teds.append(t)
    free = [strings.add(s) for _, s in FREE_STRINGS]
    if len(strings.data) & 1:
        strings.data += b'\0'

    str_at = hdr
    frstr_at = str_at + len(strings.data)
    ted_at = frstr_at + 4 * len(free)
    obj_at = ted_at + 28 * len(teds)
    nobs = sum(len(t) for t in trees)
    trindex_at = obj_at + 24 * nobs
    size = trindex_at + 4 * len(trees)

    out = bytearray()
    out += struct.pack('>18H',
                       0,                   # rsh_vrsn
                       obj_at,              # rsh_object
                       ted_at,              # rsh_tedinfo
                       obj_at,              # rsh_iconblk (none)
                       obj_at,              # rsh_bitblk (none)
                       frstr_at,            # rsh_frstr
                       str_at,              # rsh_string
                       obj_at,              # rsh_imdata (none)
                       obj_at,              # rsh_frimg (none)
                       trindex_at,          # rsh_trindex
                       nobs,                # rsh_nobs
                       len(trees),          # rsh_ntree
                       len(teds), 0, 0,     # rsh_nted, rsh_nib, rsh_nbb
                       len(free),           # rsh_nstring
                       0,                   # rsh_nimages
                       size)                # rsh_rssize
    out += strings.data
    for f in free:
        out += struct.pack('>L', str_at + f)
    for t in teds:
        out += struct.pack('>LLLhhhHhhhh',
                           str_at + t['_text'], str_at + t['_empty'],
                           str_at + t['_empty'], IBM, 0, t['just'],
                           t['color'], 0, t['thickness'],
                           len(t['text']) + 1, 1)
    roots = []
    for objs in trees:
        roots.append(len(out))
        for o in objs:
            if o['type'] in TEXT_TYPES:
                spec = str_at + o['_str']
            elif o['type'] in TED_TYPES:
                spec = ted_at + 28 * o['_ted']
            else:
                spec = o['spec']
            out += struct.pack('>hhhHHHLHHHH', o['next'], o['head'], o['tail'],
                               o['type'], o['flags'], o['state'] & 0xFFFF,
                               spec & 0xFFFFFFFF, coord(o['x']), coord(o['y']),
                               coord(o['w']), coord(o['h']))
    for r in roots:
        out += struct.pack('>L', r)
    assert len(out) == size
    return bytes(out), trees


def header(trees):
    lines = ['; rsc.i - written by tools/mkrsc.py, do not edit', '']
    for t, objs in enumerate(trees):
        lines.append('%-16s equ %d    ; tree' % (objs[0]['name'], t))
        for i, o in enumerate(objs[1:], 1):
            if o['name']:
                lines.append('%-16s equ %d' % (o['name'], i))
        lines.append('')
    lines.append('; free strings')
    for i, (name, _) in enumerate(FREE_STRINGS):
        lines.append('%-16s equ %d' % (name, i))
    lines.append('')
    return '\n'.join(lines)


# ---------------------------------------------------------------- dump

def dump(path):
    d = open(path, 'rb').read()
    h = struct.unpack('>18H', d[:36])
    names = ('vrsn object tedinfo iconblk bitblk frstr string imdata frimg '
             'trindex nobs ntree nted nib nbb nstring nimages rssize').split()
    print(' '.join('%s=%d' % kv for kv in zip(names, h)))
    obj_at, frstr_at, trindex_at = h[1], h[5], h[9]

    def cstr(off):
        return d[off:d.index(b'\0', off)].decode('latin-1')

    for t in range(h[11]):
        root, = struct.unpack('>L', d[trindex_at + 4 * t:trindex_at + 4 * t + 4])
        print('tree %d' % t)
        i = 0
        while True:
            o = struct.unpack('>hhhHHHLHHHH', d[root + 24 * i:root + 24 * i + 24])
            nxt, head, tail, typ, flags, state, spec, x, y, w, hh = o
            if typ in TEXT_TYPES:
                text = repr(cstr(spec))
            elif typ in TED_TYPES:
                text = 'ted ' + repr(cstr(struct.unpack('>L', d[spec:spec + 4])[0]))
            else:
                text = '$%08X' % spec
            print('  %2d n%3d h%3d t%3d type %2d fl $%04X st $%04X %-24s %04X %04X %04X %04X'
                  % (i, nxt, head, tail, typ, flags, state, text, x, y, w, hh))
            if flags & LASTOB:
                break
            i += 1
    for i in range(h[15]):
        off, = struct.unpack('>L', d[frstr_at + 4 * i:frstr_at + 4 * i + 4])
        print('string %d: %r' % (i, cstr(off)))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--dump':
        dump(sys.argv[2])
    elif len(sys.argv) == 3:
        data, trees = build()
        open(sys.argv[1], 'wb').write(data)
        open(sys.argv[2], 'w').write(header(trees))
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
