; ---------------------------------------------------------------------------
; Ace screen rendering (kernel): video RAM 2400 + character RAM 2C00 to
; 1-bit pixels, only the cells that changed (shadow copy).  The front end
; expands REFRESH for its screen layout.
; GPL v2 or later.
; ---------------------------------------------------------------------------

; expand[b] = every bit of b doubled horizontally (byte -> word)
build_expand:
        lea     expand,a0
        moveq   #0,d0
.byte:  moveq   #0,d2
        moveq   #7,d3
.bit:   lsl.w   #2,d2
        btst    d3,d0
        beq.s   .z
        addq.w  #3,d2
.z:     dbra    d3,.bit
        move.w  d2,(a0)+
        addq.b  #1,d0
        bne.s   .byte
        rts

; Draw the changed Ace cells 2x wide at scr_ptr (the front end's screen
; base): \1 = 0: ST high (2 lines per Ace line, 80-byte lines), 1: ST
; medium (1 line, 160-byte lines, plane 0).  Expanded by the front end.
REFRESH macro
        move.b  ST_REDRAW(a6),d6
        bne.s   .go
        tst.b   ST_VDIRTY(a6)
        bne.s   .go
        rts
.go:    clr.b   ST_REDRAW(a6)
        clr.b   ST_VDIRTY(a6)
        lea     $2400(a5),a0                ; video RAM (32x24)
        lea     shadow,a1
        lea     $2c00(a5),a2                ; character RAM
        movea.l scr_ptr,a3
        if      \1
        lea     656(a3),a3                  ; 4 lines * 160 + 16 bytes
        else
        lea     648(a3),a3                  ; 8 lines * 80 + 8 bytes
        endif
        lea     expand,a4
        movea.l a3,a6                       ; a6 = destination of current cell
        moveq   #23,d7
.row:   moveq   #7,d5                       ; 8 groups of 4 cells
.grp:   tst.b   d6
        bne.s   .cells
        cmpm.l  (a0)+,(a1)+
        bne.s   .back
        if      \1
        lea     16(a6),a6
        else
        addq.l  #8,a6
        endif
        dbra    d5,.grp
        bra.s   .eol
.back:  subq.l  #4,a0
        subq.l  #4,a1
.cells: swap    d5
        move.w  #3,d5
.col:   move.b  (a0)+,d0
        cmp.b   (a1),d0
        bne.s   .draw
        tst.b   d6
        beq.s   .next
.draw:  move.b  d0,(a1)
        moveq   #0,d1
        move.b  d0,d1
        and.w   #$7f,d1
        lsl.w   #3,d1                       ; glyph offset
        tst.b   d0
        spl     d4                          ; $ff when not inverse
        moveq   #7,d3
.line:  move.b  (a2,d1.w),d2
        eor.b   d4,d2
        and.w   #$ff,d2
        add.w   d2,d2
        move.w  (a4,d2.w),d2
        move.w  d2,(a6)
        if      \1=0
        move.w  d2,80(a6)
        endif
        lea     160(a6),a6
        addq.w  #1,d1
        dbra    d3,.line
        lea     -1280(a6),a6
.next:  addq.l  #1,a1
        if      \1
        addq.l  #4,a6
        else
        addq.l  #2,a6
        endif
        dbra    d5,.col
        swap    d5
        dbra    d5,.grp
.eol:   lea     1280(a3),a3
        movea.l a3,a6
        dbra    d7,.row
        rts
        endm

