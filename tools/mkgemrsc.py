#!/usr/bin/env python3
"""
ACEGEM - build the resource file ACEGEM.RSC and the header acegem_rsc.h

    tools/mkgemrsc.py <out.rsc> <out.h>     write both files
    tools/mkgemrsc.py --dump <file.rsc>     list what is in a resource file

All texts of ACEGEM's user interface are in ACEGEM.RSC, so it can be
translated with a resource editor: keep the trees, the order of the objects
and the order of the free strings, change the texts.  (The writer is the
one of the CHIP-8 emulator.)

Coordinates are in characters; a value can also be given as (chars, pixels),
stored as pixels * 256 + chars.  The program sets the rows of the dialogs
itself (layout_dialog() in gem/acegem.c), so that buttons are at least 17
pixels high in every resolution; the y values here only give the order.
"""

import struct
import sys

# ---------------------------------------------------------------- types

G_BOX, G_TEXT, G_BOXTEXT, G_IMAGE, G_USERDEF, G_IBOX, G_BUTTON, \
    G_BOXCHAR, G_STRING, G_FTEXT, G_FBOXTEXT, G_ICON, G_TITLE = range(20, 33)

NONE = 0x0000
SELECTABLE, DEFAULT, EXIT, EDITABLE, RBUTTON, LASTOB, TOUCHEXIT = \
    0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040
FL3DBAK, FL3DACT, FLAG11 = 0x0400, 0x0600, 0x0800      # FLAG11: Undo key

NORMAL, SELECTED, DISABLED, OUTLINED, WHITEBAK = 0x00, 0x01, 0x08, 0x10, 0x40
SHADOWED = 0x20

# MagiC object types (CF-Lib emulates them where MagiC is missing); a
# shortcut is the position of the underlined letter
MX_TITLE = WHITEBAK | 0xFF00            # underlined title (G_STRING)
MX_FRAME = WHITEBAK | 0xFE00            # group frame (G_BUTTON)
def MX_SC(pos):                         # exit button / string with shortcut
    return WHITEBAK | (pos << 8)
def MX_CHECK(pos):                      # check box / radio with shortcut
    return WHITEBAK | 0x8000 | (pos << 8)

TEXT_TYPES = (G_BUTTON, G_STRING, G_TITLE)
TED_TYPES = (G_TEXT, G_BOXTEXT, G_FTEXT, G_FBOXTEXT)
IBM, TE_LEFT, TE_CNTR = 3, 0, 2


def ted(text, just=TE_LEFT, color=0x1180, thickness=-1, tmplt='', valid=''):
    return dict(text=text, just=just, color=color, thickness=thickness,
                tmplt=tmplt, valid=valid)


def obj(name, type_, flags, state, spec, x, y, w, h, children=()):
    return dict(name=name, type=type_, flags=flags, state=state, spec=spec,
                x=x, y=y, w=w, h=h, children=list(children))


def string(name, text, x, y, w, state=NORMAL, flags=NONE):
    return obj(name, G_STRING, flags, state, text, x, y, w, 1)




# ---------------------------------------------------------------- menu

def menu_tree():
    bar_h = (1, 2)
    title_h = (1, 3)
    titles = [('T_DESK', ' ACEGEM '), ('T_FILE', ' File '),
              ('T_EMU', ' Emulation '), ('T_OPT', ' Options ')]
    tobjs, x = [], 0
    for name, t in titles:
        tobjs.append(obj(name, G_TITLE, NONE, NORMAL, t, x, 0, len(t), title_h))
        x += len(t)
    starts = [2 + sum(len(t) for _, t in titles[:i]) for i in range(len(titles))]

    def drop(i, entries):
        w = len(entries[0][1])
        assert all(len(t) == w for _, t in entries), entries
        return obj(None, G_BOX, NONE, NORMAL, 0x00FF1100, starts[i], 0, w, len(entries),
                   [string(n, t, 0, j, w, DISABLED if n is None else NORMAL)
                    for j, (n, t) in enumerate(entries)])

    acc = [(None, '  Desk Accessory %d  ' % i) for i in range(1, 7)]
    acc_box = drop(0, [('MI_ABOUT', '  About ACEGEM...   '),
                       (None, '--------------------')] + acc)
    for o in acc_box['children'][2:]:
        o['state'] = NORMAL
    sep = '------------------------'
    return obj('MENU', G_IBOX, NONE, NORMAL, 0, 0, 0, 80, 25, [
        obj(None, G_BOX, NONE, NORMAL, 0x00001100, 0, 0, 80, bar_h, [
            obj(None, G_IBOX, NONE, NORMAL, 0, 2, 0, x, title_h, tobjs),
        ]),
        obj(None, G_IBOX, NONE, NORMAL, 0, 0, title_h, 80, 19, [
            acc_box,
            drop(1, [('MI_TAPE', '  Open tape...      ^O '),
                     ('MI_SNAP', '  Load snapshot...  ^L '),
                     (None, sep[:23]),
                     ('MI_SHOT', '  Save screenshot   ^T '),
                     (None, sep[:23]),
                     ('MI_QUIT', '  Quit              ^Q ')]),
            drop(2, [('MI_RESET', '  Reset   ^R '),
                     ('MI_PAUSE', '  Pause   ^P ')]),
            drop(3, [('MI_SETTINGS', '  Settings...  ^S '),
                     ('MI_KEYBOARD', '  Keyboard     ^K ')]),
        ]),
    ])


# ---------------------------------------------------------------- dialogs

EXITBUT = SELECTABLE | EXIT | FL3DACT
POPBOX = TOUCHEXIT | FL3DBAK
KEYSTR = TOUCHEXIT                      # label that cycles its popup

# the popup box shows the chosen text and the program finds the entry by
# comparing, so all texts have the same length
RAM_TEXTS = ('  3K ', ' 19K ', ' 35K ', ' 51K ')
assert len(set(map(len, RAM_TEXTS))) == 1
RW = len(RAM_TEXTS[0])


def key_field(name, label, lx, x, y):
    """a joystick key: its label and a 3-character field (the Ace key's
    name, as in ACE.INF) with a black border two pixels outside"""
    return [
        obj(None, G_STRING, NONE, NORMAL, label, lx, y, len(label), 1),
        obj(name, G_FBOXTEXT, EDITABLE | FL3DBAK, NORMAL,
            ted('   ', thickness=-2, tmplt='___', valid='XXX'), x, y, 3, 1),
    ]


def settings_tree():
    # Object 1 is a MagiC title (CF-Lib makes it the window title); the
    # group frames come one below the other, the button in a row below.
    keys = (key_field('D_KUP', 'Up', 10, 13, 1) +
            key_field('D_KLEFT', 'Left', 3, 8, 2) +
            key_field('D_KRIGHT', 'Right', 18, 24, 2) +
            key_field('D_KDOWN', 'Down', 8, 13, 3) +
            key_field('D_KFIRE', 'Fire', 19, 24, 3))
    return obj('SETDIAL', G_BOX, FL3DBAK, NORMAL, 0x00001100, 0, 0, 32, 12, [
        obj('D_TITLE', G_STRING, FL3DBAK, MX_TITLE, 'Settings', 1, 0, 30, (1, 2)),
        obj('D_FMEM', G_BUTTON, NONE, MX_FRAME, ' Memory ', 1, 1, 30, 2, [
            obj('D_RAMLBL', G_STRING, KEYSTR, MX_SC(0), 'RAM', 1, 1, 3, 1),
            obj('D_RAM', G_BOXTEXT, POPBOX, SHADOWED, ted(RAM_TEXTS[3]), 5, 1, RW, 1),
            obj(None, G_STRING, NONE, NORMAL, '(resets the Ace)', 12, 1, 16, 1),
        ]),
        obj('D_FJOY', G_BUTTON, NONE, MX_FRAME, ' Joystick keys ', 1, 4, 30, 4, keys),
        obj('D_CLOSE', G_BUTTON, EXITBUT | FLAG11 | DEFAULT, MX_SC(0), 'Close', 21, 10, 9, 1),
    ])


def about_tree():
    lines = ['Jupiter Ace emulator', 'for the Atari', 'Version 0.9', 'GPL v2 or later']
    return obj('ABOUT', G_BOX, FL3DBAK, NORMAL, 0x00001100, 0, 0, 30, 10, [
        obj('A_TITLE', G_STRING, FL3DBAK, MX_TITLE, 'About ACEGEM', 1, 0, 28, (1, 2)),
        obj('A_FRAME', G_BUTTON, NONE, MX_FRAME, ' ACEGEM ', 1, 1, 28, 5,
            [string('A_LINE%d' % (i + 1), t, 1, i + 1, len(t)) for i, t in enumerate(lines)]),
        obj('A_OK', G_BUTTON, EXITBUT | DEFAULT | FLAG11, MX_SC(0), 'OK', 10, 8, 10, 1),
    ])


def popup_tree(name, prefix, texts):
    w = len(texts[0])
    return obj(name, G_BOX, FL3DBAK, SHADOWED, 0x00FF1100, 0, 0, w, len(texts),
               [string('%s%d' % (prefix, i) if i == 0 else None, t, 0, i, w,
                       flags=SELECTABLE) for i, t in enumerate(texts)])


# ---------------------------------------------------------------- free strings

FREE_STRINGS = [
    ('FS_APPNAME', '  ACEGEM'),
    ('FS_WINTITLE', ' ACEGEM '),
    ('FS_PAUSED', ' ACEGEM - paused '),
    ('FS_FSEL_TAPE', 'Open a tape'),
    ('FS_FSEL_SNAP', 'Load a snapshot (.ace)'),
    ('FS_SHOTDIR', 'SCNSHT'),
    ('AL_NOVDI', '[3][ACEGEM:|No VDI workstation.][Cancel]'),
    ('AL_SMALL', '[3][ACEGEM needs a screen of|at least 256 x 192 pixels.][Cancel]'),
    ('AL_NOWINDOW', '[3][ACEGEM:|No window left.|Please close one|and try again.][Cancel]'),
    ('AL_NOROM', '[3][ACEGEM cannot read ACE.ROM|(8192 bytes, next to|the program).][Cancel]'),
    ('AL_BADOP', '[3][The Ace ran into an unknown|Z80 instruction.][ OK ]'),
    ('AL_RAM', '[2][The new RAM size needs|a reset of the Ace.][Reset|Cancel]'),
    ('AL_NOSNAP', '[1][This is not a Jupiter Ace|snapshot (.ace).][ OK ]'),
    ('AL_NOFILE', '[1][The file cannot be read.][ OK ]'),
    ('AL_NOMEM', '[1][Not enough memory.][ OK ]'),
    ('AL_SHOT', '[3][The screenshot could not|be saved.][Cancel]'),
    ('FS_SHOTSAVED', ' ACEGEM - saved '),
    ('FS_KBTITLE', ' Jupiter Ace keyboard '),
    ('AL_COLDFIRE', '[3][ACEGEM needs a 68000-family|CPU. It does not run on|ColdFire.][Cancel]'),
]

TREES = [menu_tree(), settings_tree(), about_tree(),
         popup_tree('RAMPOP', 'R_', RAM_TEXTS)]


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


def all_free_strings(trees):
    return FREE_STRINGS


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
                t['_tmplt'] = strings.add(t.get('tmplt', ''))
                t['_valid'] = strings.add(t.get('valid', ''))
                o['_ted'] = len(teds)
                teds.append(t)
    free = [strings.add(s) for _, s in all_free_strings(trees)]
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
                           str_at + t['_text'], str_at + t['_tmplt'],
                           str_at + t['_valid'], IBM, 0, t['just'],
                           t['color'], 0, t['thickness'],
                           len(t['text']) + 1, len(t.get('tmplt', '')) + 1)
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
    lines = ['/* acegem_rsc.h - written by tools/mkgemrsc.py, do not edit */', '',
             '#ifndef ACEGEM_RSC_H', '#define ACEGEM_RSC_H', '']
    for t, objs in enumerate(trees):
        lines.append('#define %-16s %d    /* tree */' % (objs[0]['name'], t))
        for i, o in enumerate(objs[1:], 1):
            if o['name']:
                lines.append('#define %-16s %d' % (o['name'], i))
        lines.append('')
    lines.append('/* free strings */')
    for i, (name, _) in enumerate(all_free_strings(trees)):
        lines.append('#define %-16s %d' % (name, i))
    lines += ['', '#endif', '']
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
