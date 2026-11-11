; ---------------------------------------------------------------------------
; Video: ST high (640x400 mono) or ST medium (640x200, two bitplanes).  The
; Ace screen is 32x24 characters of 8x8 pixels.  Mono: drawn 2x2 scaled
; (512x384), centred: 8 lines down, 8 bytes in.  Medium: 2x wide (512x192),
; 4 lines down, 64 pixels in, plane 0 only (plane 1 stays set from the
; black clear; main.s pal_ace makes colour 2 white and 3 black).  1 = black and
; the Ace shows white ink on black, so glyph bytes are inverted; the Ace
; "inverse" bit (bit 7 of the screen byte) cancels that.  Either way a
; character row is 1280 bytes of screen.
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

; \1 = 0: mono, 1: medium
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

; Redraw changed cells (or all when ST_REDRAW is set).  Called from
; host_service with all registers saved.  Does nothing unless video RAM
; (ST_VDIRTY) or character RAM (ST_REDRAW) was written since the last call;
; all such writes go through store_low.  Compares four cells at a time with
; the shadow copy and draws only the cells of groups that differ.
refresh_screen:
        tst.b   medium
        bne     refresh_med
        REFRESH 0
refresh_med:
        REFRESH 1

