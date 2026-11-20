; ---------------------------------------------------------------------------
; GEM sessions (file selector, alerts, settings dialog) and .ace snapshots.
;
; gem_enter / gem_leave hand keyboard, mouse and colours back to TOS for a
; while: the Ace stops, the AES runs in user mode on our stack.  Without an
; AES (started from AUTO) gem_enter fails and nothing is shown.
;
; Snapshot (.ace, Ace32 / EightyOne format): Ace memory from 0x2000 up,
; packed: ED n b = n times b, ED 00 = end; everything else is literal.
; In the first video copy (0x2000-0x23FF, the real screen is 0x2400):
;   2000  01 80 00 00     tag
;   2081  RAMTOP / 256    (40 = 3K, 80 = 19K, C0 = 35K, 00 = 51K)
;   2100  AF BC DE HL IX IY SP PC AF' BC' DE' HL' (low byte first), then
;         IM IFF1 IFF2 I R, every value in 4 bytes.
; GPL v2 or later.
; ---------------------------------------------------------------------------

; Enter a GEM session (from supervisor mode, Z80 registers saved by the
; caller).  d0 = 0 (Z) when the AES is there; else the caller still calls
; gem_leave.
gem_enter:
        jsr     host_snd_off
        jsr     pal_tos                     ; GEM in the desktop's colours
        move.w  #$2700,sr
        move.l  old_ikbd,$118.w
        move.w  #$2000,sr
        move.b  #$08,d0                     ; IKBD: mouse relative
        jsr     ikbd_send
        move.l  (sp)+,a1                    ; return address
        move.w  #$2700,sr                   ; user mode on this stack, the
        movea.l sp,a0                       ; system stack for exceptions
        move.l  a0,usp                      ; (GEMDOS Super moves sp here)
        movea.l old_ssp,sp
        move.w  #$0000,sr
        move.l  a1,-(sp)

        move.w  #$c9,d0                     ; AES present?
        trap    #2
        cmp.w   #$c9,d0
        beq     .none
        tst.b   aes_init
        bne.s   .inited
        move.l  #$000a0000,aes_control      ; appl_init: 10,0,1,0,0
        move.l  #$00010000,aes_control+4
        bsr     aes_call
        tst.w   aes_intout
        bmi     .none
        st      aes_init
        move.w  #$19,-(sp)                  ; Dgetdrv
        trap    #1
        addq.l  #2,sp
        lea     fs_path,a0
        add.b   #'A',d0
        move.b  d0,(a0)+
        move.b  #':',(a0)+
        clr.w   -(sp)                       ; Dgetpath(buf, current drive)
        move.l  a0,-(sp)
        move.w  #$47,-(sp)
        trap    #1
        addq.l  #8,sp
        lea     fs_path,a0
.end:   tst.b   (a0)+
        bne.s   .end
        subq.l  #1,a0
        cmp.b   #$5c,-1(a0)                 ; root may come back as "\"
        bne.s   .sl
        subq.l  #1,a0
.sl:    move.b  #$5c,(a0)+
        clr.b   (a0)
.inited:
        dc.w    $a000                       ; Line-A: show the mouse
        movea.l 8(a0),a1                    ; intin
        clr.w   (a1)                        ; 0 = show whatever the count
        dc.w    $a009
        move.w  #78,d0                      ; graf_mouse(ARROW)
        move.l  #$00010001,d1
        clr.w   aes_intin
        bsr     aes_op0
        moveq   #0,d0
        rts
.none:  moveq   #-1,d0
        rts

; Leave the GEM session: supervisor again, keyboard and joystick ours, all
; Ace keys up, black screen, full redraw next refresh.
gem_leave:
        tst.b   aes_init
        beq.s   .nm
        dc.w    $a00a                       ; hide the mouse
.nm:    move.l  (sp)+,d3                    ; return address (survives Super)
        clr.l   -(sp)                       ; Super: supervisor again
        move.w  #$20,-(sp)
        trap    #1
        addq.l  #6,sp
        move.l  d0,old_ssp
        move.l  d3,-(sp)
        move.b  #$12,d0                     ; IKBD: mouse off,
        jsr     ikbd_send
        move.b  #$14,d0                     ; joystick events
        jsr     ikbd_send
        move.w  #$2700,sr
        move.l  #ikbd_isr,$118.w
        move.w  #$2000,sr
        jsr     keys_up                     ; all Ace keys up
        clr.b   ctrl_down
        movea.l scr_ptr,a0                  ; black screen, full redraw
        moveq   #-1,d1
        move.w  #(32000/4)-1,d0
.clr:   move.l  d1,(a0)+
        dbra    d0,.clr
        jsr     pal_ace
        st      state+ST_REDRAW
        rts

aes_call:
        move.l  #aes_pb,d1
        move.w  #$c8,d0
        trap    #2
        rts

; AES call d0.w = opcode, d1 = intin count << 16 | intout count,
; d2 = addrout count << 16 | addrin count
aes_op:
        move.w  d0,aes_control
        move.l  d1,aes_control+2
        move.w  d2,aes_control+6
        swap    d2
        move.w  d2,aes_control+8
        bra.s   aes_call

aes_op0:
        moveq   #0,d2
        bra.s   aes_op

; form_alert(1, a0); d0.w = button
alert:
        move.w  #1,aes_intin
        move.l  a0,aes_addrin
        move.w  #52,d0
        move.l  #$00010001,d1
        moveq   #1,d2
        bsr     aes_op
        move.w  aes_intout,d0
        rts

; File selector.  a0 = mask ("*.ACE"), a1 = title (TOS 1.04 and later show
; it).  Result: fs_full = the whole path; d0 = 0 (Z) when a file was picked.
fsel:
        movem.l a0-a1,-(sp)
        lea     fs_path,a2                  ; mask after the last \ or :
        movea.l a2,a3
.f:     move.b  (a2)+,d0
        beq.s   .fe
        cmp.b   #$5c,d0
        beq.s   .fs
        cmp.b   #':',d0
        bne.s   .f
.fs:    movea.l a2,a3
        bra.s   .f
.fe:    movem.l (sp)+,a0-a1
.cpm:   move.b  (a0)+,(a3)+
        bne.s   .cpm
        clr.b   fs_file
        move.l  #fs_path,aes_addrin
        move.l  #fs_file,aes_addrin+4
        move.l  a1,aes_addrin+8
        move.w  #90,d0                      ; fsel_input: 90,0,2,2
        moveq   #2,d2
        cmp.w   #$0140,aes_global           ; fsel_exinput: 91,0,2,3
        bcs.s   .old
        move.w  #91,d0
        moveq   #3,d2
.old:   move.l  #$00000002,d1
        bsr     aes_op
        tst.w   aes_intout+2                ; OK?
        beq.s   .no
        tst.b   fs_file
        beq.s   .no
        lea     fs_path,a0                  ; fs_full = path up to the
        lea     fs_full,a1                  ; last \ or :, then the file
        movea.l a1,a2
.cp:    move.b  (a0)+,d0
        beq.s   .cpf
        move.b  d0,(a1)+
        cmp.b   #$5c,d0
        beq.s   .sep
        cmp.b   #':',d0
        bne.s   .cp
.sep:   movea.l a1,a2
        bra.s   .cp
.cpf:   lea     fs_file,a0
.cpn:   move.b  (a0)+,(a2)+
        bne.s   .cpn
        moveq   #0,d0
        rts
.no:    moveq   #-1,d0
        rts

; ---------------------------------------------------------------------------
; Control+O (host_service, supervisor mode, all registers saved): pick the
; tape file with the GEM file selector.  Also the settings dialog's Tape
; button (tape_pick, inside a GEM session).
; ---------------------------------------------------------------------------
tape_select:
        clr.b   open_flag
        jsr     gem_enter
        bne.s   .back
        bsr.s   tape_pick
.back:  jmp     gem_leave

; file selector for the tape; d0 = 0 (Z) when a new tape was picked
tape_pick:
        lea     tape_mask,a0
        lea     tape_title,a1
        jsr     fsel
        bne.s   .no
        lea     fs_full,a0
        lea     tapename,a1
.cp:    move.b  (a0)+,(a1)+
        bne.s   .cp
        bsr     tape_close                  ; next LOAD/SAVE opens the new file
        moveq   #0,d0
.no:    rts
