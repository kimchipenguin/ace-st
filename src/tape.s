; ---------------------------------------------------------------------------
; Tape: ROM traps (ED FC C9 at 0x18A7 = load, ED FD C9 at 0x1820 = save),
; same behaviour and file format as xAce:
;   block = 16-bit little-endian length (data+1), data, XOR checksum
; A header block (26 bytes, name at +1) is always followed by a data block.
; Tape file: TAPE.ACE in the current directory.
; GPL v2 or later (derived from xAce tape.c, Edward Patel).
;
; TODO: .TAP/.TZX support, truncating on save, fall-back images when no tape.
; ---------------------------------------------------------------------------

; GEMDOS helpers (clobber d0-d2/a0-a2 like any trap)

; read d1.l bytes to (a2); d0.l = bytes read
tape_read:
        move.l  a2,-(sp)
        move.l  d1,-(sp)
        move.w  tape_fh,-(sp)
        move.w  #$3f,-(sp)                  ; Fread
        trap    #1
        lea     12(sp),sp
        rts

; write d1.l bytes from (a2)
tape_write:
        move.l  a2,-(sp)
        move.l  d1,-(sp)
        move.w  tape_fh,-(sp)
        move.w  #$40,-(sp)                  ; Fwrite
        trap    #1
        lea     12(sp),sp
        rts

; seek d1.l from mode d2.w (0 start, 1 current)
tape_seek:
        move.w  d2,-(sp)
        move.w  tape_fh,-(sp)
        move.l  d1,-(sp)
        move.w  #$42,-(sp)                  ; Fseek
        trap    #1
        lea     10(sp),sp
        rts

; open (or create) the tape file once; d0.w = handle or negative
tape_open:
        move.w  tape_fh,d0
        bpl.s   .have
        move.w  #2,-(sp)                    ; read/write
        pea     tapename
        move.w  #$3d,-(sp)                  ; Fopen
        trap    #1
        addq.l  #8,sp
        tst.l   d0
        bpl.s   .got
        clr.w   -(sp)
        pea     tapename
        move.w  #$3c,-(sp)                  ; Fcreate
        trap    #1
        addq.l  #8,sp
        tst.l   d0
        bmi.s   .have
.got:   move.w  d0,tape_fh
        clr.b   tape_eof
        clr.b   tape_hdr_done
.have:  rts

tape_close:
        move.w  tape_fh,d0
        bmi.s   .n
        move.w  d0,-(sp)
        move.w  #$3e,-(sp)                  ; Fclose
        trap    #1
        addq.l  #4,sp
        move.w  #-1,tape_fh
.n:     rts

tape_rewind:
        moveq   #0,d1
        moveq   #0,d2
        bsr     tape_seek
        clr.b   tape_eof
        clr.b   tape_hdr_done
        rts

; read one block into (a3): d0 = 0 ok, -1 at end of tape.  Clobbers d3
; (only called from tape_load, which saves it).
tape_rblock:
        lea     tape_tmp,a2
        moveq   #2,d1
        bsr     tape_read
        cmp.l   #2,d0
        bne.s   .eof
        moveq   #0,d1
        move.b  tape_tmp+1,d1
        lsl.w   #8,d1
        move.b  tape_tmp,d1
        subq.l  #1,d1                       ; data bytes (length includes checksum)
        ble.s   .eof
        move.l  d1,-(sp)
        movea.l a3,a2
        bsr     tape_read
        lea     tape_tmp,a2                 ; discard the checksum
        moveq   #1,d1
        bsr     tape_read
        move.l  (sp)+,d3
        ; bytes that landed below 0x4000 go through store_low as well, so
        ; the mirrors of video, character and 1K RAM see them (one chip
        ; each on the real Ace) and a character set load forces a redraw
        move.l  a3,d1
        sub.l   a5,d1                       ; Z80 address of the block
        subq.l  #1,d3
        bmi.s   .ok
.mir:   cmp.l   #$4000,d1
        bcc.s   .ok
        move.b  (a5,d1.l),d2
        jsr     store_low
        addq.l  #1,d1
        dbra    d3,.mir
.ok:    moveq   #0,d0
        rts
.eof:   st      tape_eof
        moveq   #-1,d0
        rts

; skip one block
tape_skip:
        lea     tape_tmp,a2
        moveq   #2,d1
        bsr     tape_read
        cmp.l   #2,d0
        bne.s   .eof
        moveq   #0,d1
        move.b  tape_tmp+1,d1
        lsl.w   #8,d1
        move.b  tape_tmp,d1
        moveq   #1,d2
        bra     tape_seek
.eof:   st      tape_eof
        rts

; ROM load trap: a2 = destination (host pointer).  Requested name is at
; 0x2702 (10 chars), type byte at 0x2701.
tape_load:
        movem.l d3-d7/a0-a1/a3,-(sp)
        movea.l a2,a3
        bsr     tape_open
        tst.w   d0
        bmi.s   .out
        tst.b   tape_eof
        beq.s   .noeof
        bsr     tape_rewind
.noeof: tst.b   tape_hdr_done
        bne.s   .data
        bsr     tape_rblock                 ; header block
        tst.w   d0
        bmi.s   .out
        lea     mem+$2702,a0
        lea     1(a3),a1
        moveq   #9,d0
.cmp:   cmpm.b  (a0)+,(a1)+
        bne.s   .miss
        dbra    d0,.cmp
        move.b  #1,tape_hdr_done            ; found: next call loads the data
        bra.s   .out
.miss:  bsr     tape_skip                   ; wrong file: skip its data block
        bra.s   .out
.data:  bsr     tape_rblock
        clr.b   tape_hdr_done
.out:   movem.l (sp)+,d3-d7/a0-a1/a3
        rts

; ROM save trap: a2 = source (host pointer), d2.w = size
tape_save:
        movem.l d3-d7/a0-a1/a3,-(sp)
        movea.l a2,a3
        moveq   #0,d5
        move.w  d2,d5                       ; size
        bsr     tape_open
        tst.w   d0
        bmi.s   .out
        lea     tape_tmp,a2                 ; length = size+1, little endian
        move.l  d5,d0
        addq.w  #1,d0
        move.b  d0,(a2)
        lsr.w   #8,d0
        move.b  d0,1(a2)
        moveq   #2,d1
        bsr     tape_write
        movea.l a3,a2                       ; data
        move.l  d5,d1
        bsr     tape_write
        moveq   #0,d0                       ; XOR checksum
        movea.l a3,a0
        move.l  d5,d1
        beq.s   .cs
        subq.w  #1,d1
.x:     move.b  (a0)+,d2
        eor.b   d2,d0
        dbra    d1,.x
.cs:    move.b  d0,tape_tmp
        lea     tape_tmp,a2
        moveq   #1,d1
        bsr     tape_write
.out:   movem.l (sp)+,d3-d7/a0-a1/a3
        rts
