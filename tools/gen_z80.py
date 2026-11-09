#!/usr/bin/env python3
"""
Generates src/z80ops.s (Z80 opcode handlers + dispatch tables) and
src/tables.s (parity table, ST scancode -> Ace keyboard matrix).

Register conventions and helper macros are documented in src/macros.s.
Every handler ends in NEXT (or jumps to do_int via CHKINT before it).

GPL v2 or later; keyboard matrix data derived from xAce.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'src')

out = []
tables = {'o': {}, 'cb': {}, 'ed': {}, 'dd': {}, 'fd': {}, 'ddcb': {}}
_cnt = [0]


def emit(s=''):
    out.append(s)


mains = {}          # main-page handler bodies, placed in 256-byte slots
# main handlers longer than a slot: the slot jumps to the body elsewhere
OVERSIZE = set()


def handler(tab, code, lines, tail='NEXT'):
    name = '%s_%02x' % (tab, code)
    assert code not in tables[tab], name
    tables[tab][code] = name
    body = [l if l.startswith('.') else '        ' + l for l in lines]
    if tail:
        body.append('        ' + tail)
    if tab == 'o':
        mains[code] = body
        return
    emit('%s:' % name)
    out.extend(body)
    emit()


def slots():
    """Main-page handlers at slot_mid + (opcode << 8 as a signed word):
    0x80-0xFF below slot_mid, 0x00-0x7F above.  NEXT jumps there with no
    table.  Each slot is padded to 256 bytes; an oversized handler makes
    the dcb.b count negative and vasm stops."""
    emit('; ---- main opcode slots (256 bytes each, see NEXT) ----')
    emit('        even')
    emit('slot_base:')
    order = list(range(0x80, 0x100)) + list(range(0x80))
    for i, code in enumerate(order):
        name = 'o_%02x' % code
        emit('%s:' % name)
        if code in OVERSIZE:
            emit('        jmp     %s_x' % name)
        else:
            out.extend(mains[code])
        emit('        dcb.b   slot_base+%d-*,0' % ((i + 1) * 256))
    emit('slot_end:')
    emit()
    for code in sorted(OVERSIZE):
        emit('o_%02x_x:' % code)
        out.extend(mains[code])
        emit()


R8 = ['B', 'C', 'D', 'E', 'H', 'L', 'M', 'A']
ALU = ['ADD', 'ADC', 'SUB', 'SBC', 'AND', 'XOR', 'OR', 'CP']
PAIR = {'BC': 'd4', 'DE': 'd5', 'HL': 'd6'}
TRUE_BR = ['bne', 'beq', 'bcc', 'bcs', 'bvc', 'bvs', 'bpl', 'bmi']
FALSE_BR = ['beq', 'bne', 'bcs', 'bcc', 'bvs', 'bvc', 'bmi', 'bpl']
RR4 = ['BC', 'DE', 'HL', 'SP']

JR_TAKE = ['move.b (a0)+,d0', 'ext.w d0', 'adda.w d0,a0', 'CHKINT']


def jr(code, cc):
    lines = []
    if cc is not None:
        lines += ['move.w d3,ccr', '%s.s .s' % FALSE_BR[cc]]
    lines += JR_TAKE
    if cc is not None:
        lines += ['NEXT', '.s:', 'addq.l #1,a0']
    handler('o', code, lines)


def gen_main():
    handler('o', 0x00, [], 'NEXT')

    # LD rr,nn / LD (BC),A / LD A,(BC) etc.
    for i, rr in enumerate(RR4):
        base = i * 16
        if rr == 'SP':
            handler('o', 0x01 + base, ['RDIMM16 d1', 'SETSP d1'])
        else:
            handler('o', 0x01 + base, ['RDIMM16 %s' % PAIR[rr]])
        # INC rr / DEC rr
        if rr == 'SP':
            handler('o', 0x03 + base, ['addq.l #1,a1'])
            handler('o', 0x0B + base, ['subq.l #1,a1'])
        else:
            handler('o', 0x03 + base, ['addq.w #1,%s' % PAIR[rr]])
            handler('o', 0x0B + base, ['subq.w #1,%s' % PAIR[rr]])
        # ADD HL,rr
        if rr == 'SP':
            ln = ['SP2W d2', 'add.w d2,d6', 'CFLAG']
        else:
            ln = ['add.w %s,d6' % PAIR[rr], 'CFLAG']
        handler('o', 0x09 + base, ln)

    handler('o', 0x02, ['move.l d4,d1', 'move.b d7,d2', 'STORE'])
    handler('o', 0x12, ['move.l d5,d1', 'move.b d7,d2', 'STORE'])
    handler('o', 0x0A, ['move.b (a5,d4.l),d7'])
    handler('o', 0x1A, ['move.b (a5,d5.l),d7'])
    handler('o', 0x22, ['RDIMM16 d1', 'move.w d6,d2', 'STOREW'])
    handler('o', 0x2A, ['RDIMM16 d1', 'RDW d6'])
    handler('o', 0x32, ['RDIMM16 d1', 'move.b d7,d2', 'STORE'])
    handler('o', 0x3A, ['RDIMM16 d1', 'move.b (a5,d1.l),d7'])

    # INC r / DEC r / LD r,n
    for r in range(8):
        n = R8[r]
        handler('o', 0x04 + 8 * r,
                ['GET_%s' % n, 'addq.b #1,d2', 'INCFLAGS', 'PUT_%s' % n])
        handler('o', 0x05 + 8 * r,
                ['GET_%s' % n, 'subq.b #1,d2', 'INCFLAGS', 'PUT_%s' % n])
        handler('o', 0x06 + 8 * r, ['move.b (a0)+,d2', 'PUT_%s' % n])

    # rotates on A (only C affected)
    handler('o', 0x07, ['rol.b #1,d7', 'CFLAG'])
    handler('o', 0x0F, ['ror.b #1,d7', 'CFLAG'])
    handler('o', 0x17, ['SETX', 'roxl.b #1,d7', 'CFLAG'])
    handler('o', 0x1F, ['SETX', 'roxr.b #1,d7', 'CFLAG'])
    handler('o', 0x27, ['jmp unimpl'], None)           # DAA (needs H/N)
    handler('o', 0x2F, ['not.b d7'])                   # CPL
    handler('o', 0x37, ['or.b #$11,d3'])               # SCF
    handler('o', 0x3F, ['eor.b #1,d3'])                # CCF

    # EX AF,AF'
    handler('o', 0x08, [
        'move.b d7,d0', 'move.b ST_A2(a6),d7', 'move.b d0,ST_A2(a6)',
        'move.w d3,d0', 'move.w ST_F2(a6),d3', 'move.w d0,ST_F2(a6)'])

    # jumps
    # DJNZ $ (jump to itself) is a pure delay loop: finish it in one step
    handler('o', 0x10, [
        'cmp.b #$fe,(a0)', 'bne.s .n', 'and.w #$00ff,d4', 'addq.l #1,a0',
        'NEXT', '.n:',
        'sub.w #$0100,d4', 'move.w d4,d0', 'lsr.w #8,d0', 'beq.s .s'] +
        JR_TAKE + ['NEXT', '.s:', 'addq.l #1,a0'])
    jr(0x18, None)
    for cc in range(4):
        jr(0x20 + 8 * cc, cc)

    # HALT and LD r,r'
    handler('o', 0x76, [
        '.w:', 'tst.b ST_INT(a6)', 'beq.s .w', 'jmp do_int'], None)
    for d in range(8):
        for s in range(8):
            code = 0x40 + d * 8 + s
            if code == 0x76:
                continue
            if d == s and d != 6:
                handler('o', code, [])
            else:
                handler('o', code, ['GET_%s' % R8[s], 'PUT_%s' % R8[d]])

    # ALU A,r / ALU A,n
    for op in range(8):
        for s in range(8):
            handler('o', 0x80 + op * 8 + s,
                    ['GET_%s' % R8[s], 'A_%s' % ALU[op]])
        handler('o', 0xC6 + op * 8, ['move.b (a0)+,d2', 'A_%s' % ALU[op]])

    # RET / JP / CALL / RST conditional and unconditional
    for cc in range(8):
        handler('o', 0xC0 + 8 * cc, [
            'move.w d3,ccr', '%s.s .s' % FALSE_BR[cc], 'DORET', '.s:'])
        handler('o', 0xC2 + 8 * cc, [
            'move.w d3,ccr', '%s.s .s' % FALSE_BR[cc],
            'RDIMM16 d1', 'lea (a5,d1.l),a0', 'CHKINT', 'NEXT',
            '.s:', 'addq.l #2,a0'])
        handler('o', 0xC4 + 8 * cc, [
            'move.w d3,ccr', '%s.s .s' % FALSE_BR[cc],
            'RDIMM16 d1', 'move.l a0,d0', 'sub.l a5,d0',
            'PUSH16 d0,d2', 'lea (a5,d1.l),a0', 'CHKINT', 'NEXT',
            '.s:', 'addq.l #2,a0'])
        if cc in (2, 3):
            # RST 10 / RST 18: the ROM's Forth data stack push / pop of DE,
            # done natively (see ds_push / ds_pop in z80core.s)
            handler('o', 0xC7 + 8 * cc,
                    ['jmp %s' % ('ds_push' if cc == 2 else 'ds_pop')], '')
            continue
        handler('o', 0xC7 + 8 * cc, [
            'move.l a0,d0', 'sub.l a5,d0', 'PUSH16 d0,d2',
            'lea $%02x(a5),a0' % (8 * cc), 'CHKINT'])
    handler('o', 0xC9, ['DORET'])
    handler('o', 0xC3, ['RDIMM16 d1', 'lea (a5,d1.l),a0', 'CHKINT'])
    handler('o', 0xCD, [
        'RDIMM16 d1', 'move.l a0,d0', 'sub.l a5,d0', 'PUSH16 d0,d2',
        'lea (a5,d1.l),a0', 'CHKINT'])

    # PUSH / POP
    for i, rr in enumerate(['BC', 'DE', 'HL']):
        handler('o', 0xC5 + 16 * i, ['PUSH16 %s,d0' % PAIR[rr]])
        handler('o', 0xC1 + 16 * i, ['POP16 %s' % PAIR[rr]])
    handler('o', 0xF5, ['jsr f_to_z80', 'move.b d7,-(a1)', 'move.b d0,-(a1)'])
    handler('o', 0xF1, ['move.b (a1)+,d0', 'jsr z80_to_f', 'move.b (a1)+,d7'])

    # I/O
    handler('o', 0xD3, ['move.b (a0)+,d0', 'move.b d7,d1', 'move.b d7,d2',
                        'jsr out_port'])
    handler('o', 0xDB, ['move.b (a0)+,d0', 'move.b d7,d1', 'jsr in_port',
                        'move.b d2,d7'])

    # exchanges and misc
    handler('o', 0xD9, [
        'move.w d4,d0', 'move.w ST_BC2(a6),d4', 'move.w d0,ST_BC2(a6)',
        'move.w d5,d0', 'move.w ST_DE2(a6),d5', 'move.w d0,ST_DE2(a6)',
        'move.w d6,d0', 'move.w ST_HL2(a6),d6', 'move.w d0,ST_HL2(a6)'])
    handler('o', 0xEB, ['exg d5,d6'])
    handler('o', 0xE3, [
        'moveq #0,d0', 'move.b 1(a1),d0', 'lsl.w #8,d0', 'move.b (a1),d0',
        'move.b d6,(a1)', 'move.w d6,d1', 'lsr.w #8,d1', 'move.b d1,1(a1)',
        'move.w d0,d6'])
    handler('o', 0xE9, ['lea (a5,d6.l),a0'])
    handler('o', 0xF9, ['SETSP d6'])
    handler('o', 0xF3, ['clr.b ST_IFF1(a6)', 'clr.b ST_IFF2(a6)'])
    handler('o', 0xFB, ['move.b #1,ST_IFF1(a6)', 'move.b #1,ST_IFF2(a6)'])

    # prefixes
    handler('o', 0xCB, ['NEXTP cb_table'], None)
    handler('o', 0xED, ['NEXTP ed_table'], None)
    handler('o', 0xDD, ['NEXTP dd_table'], None)
    handler('o', 0xFD, ['NEXTP fd_table'], None)


# ---------------------------------------------------------------------------
# CB page.  Bodies operate on d2.b and leave flags in d3.
# ---------------------------------------------------------------------------
def cb_body(x, y):
    if x == 0:
        if y == 0:
            return ['rol.b #1,d2', 'move.w sr,d3', 'PAR d2']
        if y == 1:
            return ['ror.b #1,d2', 'move.w sr,d3', 'PAR d2']
        if y == 2:
            return ['SETX', 'roxl.b #1,d2', 'move.w sr,d3', 'PAR d2']
        if y == 3:
            return ['SETX', 'roxr.b #1,d2', 'move.w sr,d3', 'PAR d2']
        if y == 4:
            return ['asl.b #1,d2', 'move.w sr,d3', 'and.b #$fd,d3', 'PAR d2']
        if y == 5:
            return ['asr.b #1,d2', 'move.w sr,d3', 'and.b #$fd,d3', 'PAR d2']
        if y == 6:
            return None                                # SLL (undocumented)
        return ['lsr.b #1,d2', 'move.w sr,d3', 'PAR d2']
    if x == 1:
        return ['btst #%d,d2' % y, 'move.w sr,d0', 'and.b #4,d0',
                'and.b #1,d3', 'or.b d0,d3', 'lsr.b #1,d0', 'or.b d0,d3']
    if x == 2:
        return ['bclr #%d,d2' % y]
    return ['bset #%d,d2' % y]


def gen_cb():
    for op in range(256):
        x, y, z = op >> 6, (op >> 3) & 7, op & 7
        body = cb_body(x, y)
        if body is None:
            handler('cb', op, ['jmp unimpl'], None)
            continue
        lines = ['GET_%s' % R8[z]] + body
        if x != 1:
            lines.append('PUT_%s' % R8[z])
        handler('cb', op, lines)


def gen_ddcb():
    """DD CB d op / FD CB d op: d1 already holds the effective address."""
    for op in range(256):
        x, y = op >> 6, (op >> 3) & 7
        body = cb_body(x, y)
        if body is None:
            handler('ddcb', op, ['jmp unimpl'], None)
            continue
        lines = ['move.b (a5,d1.l),d2'] + body
        if x != 1:
            lines.append('STORE')
        handler('ddcb', op, lines)


# ---------------------------------------------------------------------------
# ED page
# ---------------------------------------------------------------------------
def gen_ed():
    for r in range(8):
        if r == 6:
            lines = ['move.b d4,d0', 'move.w d4,d1', 'lsr.w #8,d1',
                     'jsr in_port', 'INFLAGS']
            handler('ed', 0x40 + 8 * r, lines)
            handler('ed', 0x41 + 8 * r, [
                'moveq #0,d2', 'move.b d4,d0', 'move.w d4,d1', 'lsr.w #8,d1',
                'jsr out_port'])
            continue
        n = R8[r]
        handler('ed', 0x40 + 8 * r, [
            'move.b d4,d0', 'move.w d4,d1', 'lsr.w #8,d1', 'jsr in_port',
            'INFLAGS', 'PUT_%s' % n])
        handler('ed', 0x41 + 8 * r, [
            'GET_%s' % n, 'move.b d4,d0', 'move.w d4,d1', 'lsr.w #8,d1',
            'jsr out_port'])

    for i, rr in enumerate(RR4):
        base = 16 * i
        if rr == 'SP':
            pre = ['SP2W d2']
            opn = 'd2'
        else:
            pre = []
            opn = PAIR[rr]
        handler('ed', 0x42 + base,
                pre + ['SETX', 'subx.w %s,d6' % opn, 'move.w sr,d3'])
        handler('ed', 0x4A + base,
                pre + ['SETX', 'addx.w %s,d6' % opn, 'move.w sr,d3'])
        # LD (nn),rr / LD rr,(nn)
        if rr == 'SP':
            handler('ed', 0x43 + base, [
                'RDIMM16 d1', 'SP2W d2', 'STOREW'])
            handler('ed', 0x4B + base, [
                'RDIMM16 d1', 'RDW d2', 'SETSP d2'])
        else:
            handler('ed', 0x43 + base, [
                'RDIMM16 d1', 'move.w %s,d2' % PAIR[rr], 'STOREW'])
            handler('ed', 0x4B + base, ['RDIMM16 d1', 'RDW %s' % PAIR[rr]])

    for code in (0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C):
        handler('ed', code, ['neg.b d7', 'move.w sr,d3'])
    for code in (0x45, 0x55, 0x65, 0x75):                     # RETN
        handler('ed', code, ['move.b ST_IFF2(a6),ST_IFF1(a6)', 'DORET'])
    for code in (0x4D, 0x5D, 0x6D, 0x7D):                     # RETI
        handler('ed', code, ['move.b ST_IFF2(a6),ST_IFF1(a6)', 'DORET'])
    for code, m in ((0x46, 0), (0x66, 0), (0x4E, 0), (0x6E, 0),
                    (0x56, 1), (0x76, 1), (0x5E, 2), (0x7E, 2)):
        handler('ed', code, ['move.b #%d,ST_IM(a6)' % m])
    handler('ed', 0x47, ['move.b d7,ST_I(a6)'])
    handler('ed', 0x4F, [])
    handler('ed', 0x57, ['move.b ST_I(a6),d7', 'LDAIR'])
    handler('ed', 0x5F, ['move.b $4bb.w,d7', 'LDAIR'])        # LD A,R ~ 200 Hz tick

    # block transfers
    for code, step, rep in ((0xA0, 'addq', False), (0xA8, 'subq', False),
                            (0xB0, 'addq', True), (0xB8, 'subq', True)):
        body = ['move.b (a5,d6.l),d2', 'move.l d5,d1', 'STORE',
                '%s.w #1,d6' % step, '%s.w #1,d5' % step, 'subq.w #1,d4']
        if rep:
            handler('ed', code, ['.l:'] + body + [
                'bne.s .l', 'and.b #$1d,d3'])
        else:
            handler('ed', code, body + [
                'and.b #$1d,d3', 'tst.w d4', 'beq.s .z', 'or.b #2,d3', '.z:'])

    # block compares
    for code, step, rep in ((0xA1, 'addq', False), (0xA9, 'subq', False),
                            (0xB1, 'addq', True), (0xB9, 'subq', True)):
        body = ['move.b (a5,d6.l),d2', 'cmp.b d2,d7', 'move.w sr,d1',
                '%s.w #1,d6' % step, 'subq.w #1,d4']
        fin = ['and.b #$0c,d1', 'and.b #$01,d3', 'or.b d1,d3',
               'tst.w d4', 'beq.s .z', 'or.b #2,d3', '.z:']
        if rep:
            handler('ed', code, ['.l:'] + body + [
                'btst #2,d1', 'bne.s .e', 'tst.w d4', 'bne.s .l', '.e:'] + fin)
        else:
            handler('ed', code, body + fin)

    # tape traps (patched into the ROM at 0x18A7 and 0x1820, see main.s)
    handler('ed', 0xFC, ['lea (a5,d6.l),a2', 'jsr tape_load', 'or.b #$11,d3'])
    handler('ed', 0xFD, ['lea (a5,d6.l),a2', 'move.w d5,d2', 'jsr tape_save'])
    # native ROM keyboard scan (patched into the ROM at 0x0336, see z80core.s)
    handler('ed', 0xFE, ['jsr kb_scan'])
    # native Forth checks + NEXT (patched into the ROM at 0x04C8, see z80core.s)
    handler('ed', 0xFF, ['jmp forth_next'], '')
    # native Forth data stack pop of BC (patched into the ROM at 0x084E)
    handler('ed', 0xFB, ['jmp ds_popbc'], '')


# ---------------------------------------------------------------------------
# DD / FD pages (IX / IY)
# ---------------------------------------------------------------------------
def gen_index(tab, f):
    # LD IX,nn / LD (nn),IX / LD IX,(nn) / INC / DEC
    handler(tab, 0x21, ['RDIMM16 d0', 'move.w d0,%s(a6)' % f])
    handler(tab, 0x22, ['RDIMM16 d1', 'move.w %s(a6),d2' % f, 'STOREW'])
    handler(tab, 0x2A, ['RDIMM16 d1', 'RDW d0', 'move.w d0,%s(a6)' % f])
    handler(tab, 0x23, ['addq.w #1,%s(a6)' % f])
    handler(tab, 0x2B, ['subq.w #1,%s(a6)' % f])
    # ADD IX,rr
    for code, src in ((0x09, ['add.w d4,d2']), (0x19, ['add.w d5,d2']),
                      (0x29, ['add.w d2,d2']),
                      (0x39, ['SP2W d1', 'add.w d1,d2'])):
        handler(tab, code, ['move.w %s(a6),d2' % f] + src +
                ['CFLAG', 'move.w d2,%s(a6)' % f])
    handler(tab, 0xE5, ['move.w %s(a6),d2' % f, 'PUSH16 d2,d0'])
    handler(tab, 0xE1, ['POP16 d2', 'move.w d2,%s(a6)' % f])
    handler(tab, 0xE9, ['moveq #0,d0', 'move.w %s(a6),d0' % f,
                        'lea (a5,d0.l),a0'])
    handler(tab, 0xF9, ['moveq #0,d0', 'move.w %s(a6),d0' % f, 'SETSP d0'])
    handler(tab, 0xE3, [
        'moveq #0,d0', 'move.b 1(a1),d0', 'lsl.w #8,d0', 'move.b (a1),d0',
        'move.w %s(a6),d1' % f, 'move.b d1,(a1)', 'lsr.w #8,d1',
        'move.b d1,1(a1)', 'move.w d0,%s(a6)' % f])

    ix = 'IXADDR %s' % f
    handler(tab, 0x34, [ix, 'move.b (a5,d1.l),d2', 'addq.b #1,d2',
                        'INCFLAGS', 'STORE'])
    handler(tab, 0x35, [ix, 'move.b (a5,d1.l),d2', 'subq.b #1,d2',
                        'INCFLAGS', 'STORE'])
    handler(tab, 0x36, [ix, 'move.b (a0)+,d2', 'STORE'])
    for r in (0, 1, 2, 3, 4, 5, 7):
        handler(tab, 0x46 + 8 * r, [ix, 'move.b (a5,d1.l),d2',
                                    'PUT_%s' % R8[r]])
        handler(tab, 0x70 + r, [ix, 'GET_%s' % R8[r], 'STORE'])
    for op in range(8):
        handler(tab, 0x86 + 8 * op, [ix, 'move.b (a5,d1.l),d2',
                                     'A_%s' % ALU[op]])
    handler(tab, 0xCB, [ix, 'NEXTP ddcb_table'], None)


def table(name, tab, default):
    emit('%s_table:' % name)
    row = []
    for code in range(256):
        tgt = tables[tab].get(code)
        if tgt is None:
            tgt = default(code)
        row.append(tgt)
        if len(row) == 8:
            emit('        dc.l    ' + ','.join(row))
            row = []
    emit()


def write_ops():
    emit('; GENERATED by tools/gen_z80.py -- do not edit')
    emit()
    gen_main()
    gen_cb()
    gen_ed()
    gen_index('dd', 'ST_IX')
    gen_index('fd', 'ST_IY')
    gen_ddcb()
    body = out[2:]
    del out[2:]
    slots()
    out.extend(body)
    emit('o_bad:')
    emit('        jmp     unimpl')
    emit()
    for code in range(256):
        assert code in tables['o'], 'missing main %02x' % code
    for code in range(256):
        assert code in tables['cb'], 'missing cb %02x' % code
        assert code in tables['ddcb'], 'missing ddcb %02x' % code
    emit('; ---- prefix dispatch tables (handler addresses) ----')
    table('cb', 'cb', lambda c: 'o_bad')
    table('ed', 'ed', lambda c: 'o_00')                # unknown ED = NOP
    table('dd', 'dd', lambda c: 'o_%02x' % c)          # prefix ignored
    table('fd', 'fd', lambda c: 'o_%02x' % c)
    table('ddcb', 'ddcb', lambda c: 'o_bad')
    with open(os.path.join(SRC, 'z80ops.s'), 'w') as fh:
        fh.write('\n'.join(out) + '\n')


# ---------------------------------------------------------------------------
# tables.s: parity table and keyboard map
# ---------------------------------------------------------------------------
# Ace matrix: (row, bit).  Row index = position of the 0 bit in the port
# high byte (row 0 = 0xFE ... row 7 = 0x7F).  From xAce keyboard.c.
KEY = {}
for name, (row, bit) in {
        'SHIFT': (0, 0), 'SYM': (0, 1), 'Z': (0, 2), 'X': (0, 3), 'C': (0, 4),
        'A': (1, 0), 'S': (1, 1), 'D': (1, 2), 'F': (1, 3), 'G': (1, 4),
        'Q': (2, 0), 'W': (2, 1), 'E': (2, 2), 'R': (2, 3), 'T': (2, 4),
        '1': (3, 0), '2': (3, 1), '3': (3, 2), '4': (3, 3), '5': (3, 4),
        '0': (4, 0), '9': (4, 1), '8': (4, 2), '7': (4, 3), '6': (4, 4),
        'P': (5, 0), 'O': (5, 1), 'I': (5, 2), 'U': (5, 3), 'Y': (5, 4),
        'ENTER': (6, 0), 'L': (6, 1), 'K': (6, 2), 'J': (6, 3), 'H': (6, 4),
        'SPACE': (7, 0), 'M': (7, 1), 'N': (7, 2), 'B': (7, 3), 'V': (7, 4),
}.items():
    KEY[name] = (row, 1 << bit)

# ST scancode -> list of Ace keys (max 2)
ST = {}
for sc, k in zip(range(0x02, 0x0C), '1234567890'):
    ST[sc] = [k]
for sc, k in zip(range(0x10, 0x1A), 'QWERTYUIOP'):
    ST[sc] = [k]
for sc, k in zip(range(0x1E, 0x27), 'ASDFGHJKL'):
    ST[sc] = [k]
for sc, k in zip(range(0x2C, 0x33), 'ZXCVBNM'):
    ST[sc] = [k]
ST.update({
    0x39: ['SPACE'], 0x1C: ['ENTER'], 0x72: ['ENTER'],
    0x2A: ['SHIFT'], 0x36: ['SHIFT'], 0x38: ['SYM'],
    0x01: ['SHIFT', 'SPACE'],                    # Esc = BREAK
    0x0E: ['SHIFT', '0'], 0x53: ['SHIFT', '0'],  # Backspace/Delete = DELETE
    0x4B: ['SHIFT', '5'], 0x50: ['SHIFT', '6'],  # Left, Down
    0x48: ['SHIFT', '7'], 0x4D: ['SHIFT', '8'],  # Up, Right
    # punctuation = Symbol Shift + key (physical position, as on the Ace)
    0x0C: ['SYM', 'J'], 0x0D: ['SYM', 'L'], 0x27: ['SYM', 'O'],
    0x28: ['SYM', '7'], 0x33: ['SYM', 'N'], 0x34: ['SYM', 'M'],
    0x35: ['SYM', 'V'], 0x1A: ['SYM', 'Y'], 0x1B: ['SYM', 'U'],
    0x2B: ['SYM', 'D'],
})


def write_tables():
    o = ['; GENERATED by tools/gen_z80.py -- do not edit', '',
         '; V flag (bit 1) set when the byte has even parity', 'partab:']
    for i in range(0, 256, 16):
        vals = [2 if bin(b).count('1') % 2 == 0 else 0 for b in range(i, i + 16)]
        o.append('        dc.b    ' + ','.join(str(v) for v in vals))
    o += ['', '; ST scancode -> up to two Ace matrix keys: row,mask,row,mask',
          '; (row $ff = unused)', 'keymap:']
    for sc in range(128):
        keys = ST.get(sc, [])
        ent = []
        for i in range(2):
            if i < len(keys):
                row, mask = KEY[keys[i]]
                ent += [row, mask]
            else:
                ent += [0xFF, 0]
        o.append('        dc.b    %s' % ','.join('$%02x' % v for v in ent))
    with open(os.path.join(SRC, 'tables.s'), 'w') as fh:
        fh.write('\n'.join(o) + '\n')


if __name__ == '__main__':
    write_ops()
    write_tables()
    print('wrote z80ops.s (%d lines) and tables.s' % len(out))
