; ---------------------------------------------------------------------------
; Video: ST high (640x400 mono).  The Ace screen is 32x24 characters of 8x8
; pixels.  It is drawn 2x2 scaled (512x384), centred: 8 lines down, 8 bytes in.
; ST mono has 1 = black, the Ace shows white ink on black, so glyph bytes are
; inverted; the Ace "inverse" bit (bit 7 of the screen byte) cancels that.
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

; Redraw changed cells (or all when ST_REDRAW is set).  Called from
; host_service with all registers saved.
refresh_screen:
        move.b  ST_REDRAW(a6),d6
        clr.b   ST_REDRAW(a6)
        lea     $2400(a5),a0                ; video RAM (32x24)
        lea     shadow,a1
        lea     $2c00(a5),a2                ; character RAM
        movea.l scr_ptr,a3
        lea     648(a3),a3                  ; 8 lines * 80 + 8 bytes
        lea     expand,a4
        movea.l a3,a6                       ; a6 = destination of current cell
        moveq   #23,d7
.row:   moveq   #31,d5
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
        move.w  d2,80(a6)
        lea     160(a6),a6
        addq.w  #1,d1
        dbra    d3,.line
        lea     -1280(a6),a6
.next:  addq.l  #1,a1
        addq.l  #2,a6
        dbra    d5,.col
        lea     1280(a3),a3
        movea.l a3,a6
        dbra    d7,.row
        rts
