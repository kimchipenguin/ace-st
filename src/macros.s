; ---------------------------------------------------------------------------
; ACE-ST: Jupiter Ace emulator for the Atari ST (68000, vasm Motorola syntax)
; Copyright (C) 2026
;
; This program is free software; you can redistribute it and/or modify it
; under the terms of the GNU General Public License as published by the Free
; Software Foundation; either version 2 of the License, or (at your option)
; any later version.
;
; Portions derive from xAce (Edward Patel, based on xz81 by Russell Marks,
; based on xz80 by Ian Collier; keyboard matrix by Lawrence Woodman), all GPL
; v2 or later.
; ---------------------------------------------------------------------------
;
; Register allocation while the Z80 core runs
;
;   a0  Z80 PC  as host pointer (mem + pc)
;   a1  Z80 SP  as host pointer (mem + sp; SP=0 is stored as mem+65536)
;   a2  scratch / table pointer
;   a3  unused by the core
;   a4  slot_mid: main opcode handlers at a4 + (opcode << 8, signed)
;   a5  mem     (64K Z80 address space, flat)
;   a6  state   (shadow registers, IX, IY, IFF, flags for the host)
;
;   d0-d2 scratch.  Flag helper macros only ever touch d0 so d1 can hold an
;         effective address while flags are being computed.
;   d3  Z80 flags kept as a 68000 CCR image:
;         bit0 C  bit1 V (=P/V)  bit2 Z  bit3 N (=S)  bit4 X (copy of C)
;       H and N flags are NOT tracked (DAA traps as unimplemented).
;   d4  BC  (word; upper word always zero)
;   d5  DE  (word; upper word always zero)
;   d6  HL  (word; upper word always zero)
;   d7  A   (byte)
;
; All Z80 memory accesses are byte accesses: the 68000 faults on odd words.
; ---------------------------------------------------------------------------

; state block offsets (a6)
ST_IX     equ 0            ; w
ST_IY     equ 2            ; w
ST_BC2    equ 4            ; w
ST_DE2    equ 6            ; w
ST_HL2    equ 8            ; w
ST_F2     equ 10           ; w   shadow flag image
ST_A2     equ 12           ; b
ST_INT    equ 13           ; b   set by Timer C at 50 Hz
ST_IFF1   equ 14           ; b
ST_IFF2   equ 15           ; b
ST_IM     equ 16           ; b
ST_I      equ 17           ; b
ST_REDRAW equ 18           ; b   full screen redraw requested
ST_VDIRTY equ 19           ; b   video RAM written since the last refresh
ST_SIZE   equ 20

; ---------------------------------------------------------------------------
; dispatch
; ---------------------------------------------------------------------------
NEXT    macro
        ifd     TRACE
        jsr     trace_rec
        endif
        ifd     ICOUNT
        addq.l  #1,icount
        endif
        move.b  (a0)+,-(sp)                 ; a byte pushed on a7 lands in
        move.w  (sp)+,d0                    ; the high half: d0 = op << 8
        clr.b   d0
        jmp     (a4,d0.w)                   ; slot_mid + 256 * op (signed)
        endm

; fetch the next byte and dispatch through prefix table \1 (addresses)
NEXTP   macro
        moveq   #0,d0
        move.b  (a0)+,d0
        add.w   d0,d0
        add.w   d0,d0
        lea     \1,a2
        movea.l (a2,d0.w),a2
        jmp     (a2)
        endm

; sample the 50 Hz interrupt flag at control-flow instructions
CHKINT  macro
        tst.b   ST_INT(a6)
        beq.s   .n\@
        jmp     do_int
.n\@:
        endm

; ---------------------------------------------------------------------------
; memory
; ---------------------------------------------------------------------------
; d1.l = address (upper word clear), d2.b = value.  Clobbers d0 and a2.
; The 1K user RAM (3000-3FFF, mirrored four times; Forth data stack and
; system variables) is handled inline, ROM/video/character RAM in store_low.
STORE   macro
        cmp.w   #$4000,d1
        bcc.s   .ok\@
        cmp.w   #$3000,d1
        bcs.s   .lo\@
        move.w  d1,d0
        and.w   #$03ff,d0
        lea     (a5,d0.w),a2
        move.b  d2,$3000(a2)
        move.b  d2,$3400(a2)
        move.b  d2,$3800(a2)
        move.b  d2,$3c00(a2)
        bra.s   .dn\@
.lo\@:
        jsr     store_low
        bra.s   .dn\@
.ok\@:
        move.b  d2,(a5,d1.l)
.dn\@:
        endm

; d1 = address, d2.w = value (little endian).  Clobbers d0,d1,d2,a2.
STOREW  macro
        STORE
        addq.w  #1,d1
        lsr.w   #8,d2
        STORE
        endm

; read word at (d1) into \1 (upper word cleared)
RDW     macro
        moveq   #0,\1
        move.b  1(a5,d1.l),\1
        lsl.w   #8,\1
        move.b  (a5,d1.l),\1
        endm

; 16-bit immediate from the instruction stream into \1 (upper word cleared)
RDIMM16 macro
        moveq   #0,\1
        move.b  1(a0),\1
        lsl.w   #8,\1
        move.b  (a0),\1
        addq.l  #2,a0
        endm

; push word \1 using \2 as temp
PUSH16  macro
        move.w  \1,\2
        lsr.w   #8,\2
        move.b  \2,-(a1)
        move.b  \1,-(a1)
        endm

; pop a word into register pair \1 (d4/d5/d6)
POP16   macro
        moveq   #0,\1
        move.b  (a1)+,\1
        moveq   #0,d0
        move.b  (a1)+,d0
        lsl.w   #8,d0
        or.w    d0,\1
        endm

; RET: pop PC (clobbers d0,d1)
DORET   macro
        moveq   #0,d0
        move.b  (a1)+,d0
        moveq   #0,d1
        move.b  (a1)+,d1
        lsl.w   #8,d1
        or.w    d1,d0
        lea     (a5,d0.l),a0
        CHKINT
        endm

; SP host pointer from a 16-bit value in data reg \1 (0 means 65536)
SETSP   macro
        lea     (a5,\1.l),a1
        tst.w   \1
        bne.s   .sp\@
        adda.l  #65536,a1
.sp\@:
        endm

; Z80 SP as a 16-bit value into \1.w (clobbers d0)
SP2W    macro
        move.l  a1,d0
        sub.l   a5,d0
        move.w  d0,\1
        endm

; (IX+d) / (IY+d): \1 = ST_IX or ST_IY; result d1 = address; clobbers d0
IXADDR  macro
        moveq   #0,d1
        move.b  (a0)+,d0
        ext.w   d0
        move.w  \1(a6),d1
        add.w   d0,d1
        endm

; ---------------------------------------------------------------------------
; flags (all use only d0 / a2)
; ---------------------------------------------------------------------------
; OR the parity of byte reg \1 into the V bit of d3 (d3 must hold a logic
; result with V already clear)
PAR     macro
        moveq   #0,d0
        move.b  \1,d0
        lea     partab,a2
        or.b    (a2,d0.w),d3
        endm

; load X (and a preset Z) from the Z80 carry before ADDX/SUBX/ROXL/ROXR
SETX    macro
        move.w  d3,d0
        and.w   #1,d0
        lsl.b   #4,d0
        or.b    #4,d0
        move.w  d0,ccr
        endm

; INC/DEC r: take N,Z,V from the CCR, keep the old carry
INCFLAGS macro
        move.w  sr,d0
        and.b   #$0e,d0
        and.b   #$01,d3
        or.b    d0,d3
        endm

; RLCA/ADD HL,rr etc.: take only C from the CCR, keep N,Z,V
CFLAG   macro
        move.w  sr,d0
        and.b   #$01,d0
        and.b   #$0e,d3
        or.b    d0,d3
        endm

; flags for IN r,(C): N,Z from d2, parity into V, carry kept
INFLAGS macro
        tst.b   d2
        move.w  sr,d0
        and.b   #$0c,d0
        and.b   #$01,d3
        or.b    d0,d3
        PAR     d2
        endm

; LD A,I / LD A,R flags (d7 loaded): N,Z, V = IFF2, carry kept
LDAIR   macro
        tst.b   d7
        move.w  sr,d0
        and.b   #$0c,d0
        and.b   #$01,d3
        or.b    d0,d3
        tst.b   ST_IFF2(a6)
        beq.s   .n\@
        or.b    #2,d3
.n\@:
        endm

; ---------------------------------------------------------------------------
; 8-bit operand access: value always travels in d2.b
; ---------------------------------------------------------------------------
GET_B   macro
        move.w  d4,d2
        lsr.w   #8,d2
        endm
GET_C   macro
        move.b  d4,d2
        endm
GET_D   macro
        move.w  d5,d2
        lsr.w   #8,d2
        endm
GET_E   macro
        move.b  d5,d2
        endm
GET_H   macro
        move.w  d6,d2
        lsr.w   #8,d2
        endm
GET_L   macro
        move.b  d6,d2
        endm
GET_M   macro
        move.b  (a5,d6.l),d2
        endm
GET_A   macro
        move.b  d7,d2
        endm

PUT_B   macro
        ror.w   #8,d4
        move.b  d2,d4
        rol.w   #8,d4
        endm
PUT_C   macro
        move.b  d2,d4
        endm
PUT_D   macro
        ror.w   #8,d5
        move.b  d2,d5
        rol.w   #8,d5
        endm
PUT_E   macro
        move.b  d2,d5
        endm
PUT_H   macro
        ror.w   #8,d6
        move.b  d2,d6
        rol.w   #8,d6
        endm
PUT_L   macro
        move.b  d2,d6
        endm
PUT_M   macro
        move.l  d6,d1
        STORE
        endm
PUT_A   macro
        move.b  d2,d7
        endm

; ---------------------------------------------------------------------------
; 8-bit ALU on A with operand in d2.b
; ---------------------------------------------------------------------------
A_ADD   macro
        add.b   d2,d7
        move.w  sr,d3
        endm
A_ADC   macro
        SETX
        addx.b  d2,d7
        move.w  sr,d3
        endm
A_SUB   macro
        sub.b   d2,d7
        move.w  sr,d3
        endm
A_SBC   macro
        SETX
        subx.b  d2,d7
        move.w  sr,d3
        endm
A_AND   macro
        and.b   d2,d7
        move.w  sr,d3
        PAR     d7
        endm
A_XOR   macro
        eor.b   d2,d7
        move.w  sr,d3
        PAR     d7
        endm
A_OR    macro
        or.b    d2,d7
        move.w  sr,d3
        PAR     d7
        endm
A_CP    macro
        cmp.b   d2,d7
        move.w  sr,d3
        endm
