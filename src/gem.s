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
        jsr     beep_off
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
; Snapshots
; ---------------------------------------------------------------------------

SNAPLEN equ 57344                           ; 0x2000-0xFFFF

; Read the snapshot named at (a0) into a Malloc'd buffer (snap_buf),
; unpacked, $FF after the end of the file.  d0.l: 0 = fine, -1 = cannot
; read the file, -2 = not a snapshot, -3 = no memory.
snap_read:
        movem.l d3-d7/a3-a6,-(sp)
        movea.l a0,a6
        bsr     snap_free
        move.l  #SNAPLEN,-(sp)
        move.w  #$48,-(sp)                  ; Malloc
        trap    #1
        addq.l  #6,sp
        tst.l   d0
        bgt.s   .mem
        moveq   #-3,d0
        bra     .ret
.mem:   move.l  d0,snap_buf
        movea.l d0,a3                       ; a3 = write pointer
        movea.l d0,a4
        adda.l  #SNAPLEN,a4                 ; a4 = end
        movea.l a3,a0
        moveq   #-1,d1
        move.w  #SNAPLEN/4-1,d0
.ff:    move.l  d1,(a0)+
        dbra    d0,.ff
        clr.w   -(sp)                       ; Fopen, read
        move.l  a6,-(sp)
        move.w  #$3d,-(sp)
        trap    #1
        addq.l  #8,sp
        tst.l   d0
        bmi     .bad
        move.w  d0,d6                       ; d6 = handle
        lea     rd_buf,a5                   ; a5/a6 = read buffer pos/end
        movea.l a5,a6
.lp:    bsr.s   .get
        bcs.s   .eof
        cmp.b   #$ed,d3
        beq.s   .run
        cmpa.l  a4,a3
        bcc.s   .lp
        move.b  d3,(a3)+
        bra.s   .lp
.run:   bsr.s   .get
        bcs.s   .eof
        move.b  d3,d5                       ; count, 0 = end
        beq.s   .eof
        bsr.s   .get
        bcs.s   .eof
        moveq   #0,d4
        move.b  d5,d4
        subq.w  #1,d4
.rp:    cmpa.l  a4,a3
        bcc.s   .lp
        move.b  d3,(a3)+
        dbra    d4,.rp
        bra.s   .lp
.get:   cmpa.l  a6,a5                       ; next byte in d3, C at the end
        bcs.s   .have
        pea     rd_buf
        move.l  #RDBUF,-(sp)
        move.w  d6,-(sp)
        move.w  #$3f,-(sp)                  ; Fread
        trap    #1
        lea     12(sp),sp
        tst.l   d0
        bgt.s   .got
        ori.b   #1,ccr
        rts
.got:   lea     rd_buf,a5
        lea     (a5,d0.l),a6
.have:  move.b  (a5)+,d3
        andi.b  #$fe,ccr
        rts
.eof:   move.w  d6,-(sp)
        move.w  #$3e,-(sp)                  ; Fclose
        trap    #1
        addq.l  #4,sp
        movea.l snap_buf,a0                 ; 01 80 tag, a known RAM size,
        cmp.b   #$01,(a0)                   ; and at least the registers
        bne.s   .not
        cmp.b   #$80,1(a0)
        bne.s   .not
        move.b  $81(a0),d0
        and.b   #$3f,d0
        bne.s   .not
        move.l  a3,d0
        sub.l   a0,d0
        cmp.l   #$0144,d0
        bcs.s   .not
        move.l  d0,snap_len
        moveq   #0,d0
        bra.s   .ret
.not:   bsr.s   snap_free
        moveq   #-2,d0
        bra.s   .ret
.bad:   bsr.s   snap_free
        moveq   #-1,d0
.ret:   movem.l (sp)+,d3-d7/a3-a6
        rts

snap_free:
        move.l  snap_buf,d0
        beq.s   .no
        move.l  d0,-(sp)
        move.w  #$49,-(sp)                  ; Mfree
        trap    #1
        addq.l  #6,sp
        clr.l   snap_buf
.no:    rts

; read 16 bits, low byte first, from (a2)+ (4 bytes per value) to d0.w
SNAPW   macro
        moveq   #0,d0
        move.b  1(a2),d0
        lsl.w   #8,d0
        move.b  (a2),d0
        addq.l  #4,a2
        endm

; Start the Ace from snap_buf (supervisor mode, never returns): memory,
; mirrors, RAM size and registers from the snapshot.
snap_start:
        lea     mystack_top,sp
        movea.l snap_buf,a0
        lea     mem+$2000,a1
        move.w  #SNAPLEN/4-1,d0
.cp:    move.l  (a0)+,(a1)+
        dbra    d0,.cp
        lea     mem+$2000,a0                ; header (2000-21FF) aside, the
        lea     rd_buf,a1                   ; mirrors overwrite it
        move.w  #$200/4-1,d0
.hd:    move.l  (a0)+,(a1)+
        dbra    d0,.hd
        bsr     snap_free
        lea     mem,a5
        lea     $2400(a5),a0                ; the real copies: screen 2400,
        lea     $2000(a5),a1                ; characters 2C00, 1K RAM 3C00
        bsr     .k1
        lea     $2c00(a5),a0
        lea     $2800(a5),a1
        bsr     .k1
        lea     $3c00(a5),a0
        lea     $3000(a5),a1
        bsr     .k1
        lea     $3c00(a5),a0
        bsr     .k1
        lea     $3c00(a5),a0
        bsr     .k1
        moveq   #0,d0                       ; RAM size from RAMTOP
        move.b  rd_buf+$81,d0
        lsl.w   #8,d0
        subq.w  #1,d0
        move.w  d0,ram_last
        moveq   #0,d1                       ; no RAM above it
        move.w  d0,d1
        addq.l  #1,d1
        lea     (a5,d1.l),a0
        movea.l a5,a1
        adda.l  #65536,a1
        moveq   #-1,d0
.ff:    cmpa.l  a1,a0
        bcc.s   .ffd
        move.b  d0,(a0)+
        bra.s   .ff
.ffd:
        lea     state,a6
        moveq   #ST_SIZE-1,d0
.st:    clr.b   (a6,d0.w)
        dbra    d0,.st
        lea     rd_buf+$100,a2
        SNAPW                               ; AF
        move.w  d0,-(sp)
        SNAPW                               ; BC
        move.l  d0,d4
        SNAPW                               ; DE
        move.l  d0,d5
        SNAPW                               ; HL
        move.l  d0,d6
        SNAPW
        move.w  d0,ST_IX(a6)
        SNAPW
        move.w  d0,ST_IY(a6)
        SNAPW                               ; SP
        move.l  d0,d7
        bne.s   .sp
        move.l  #65536,d7
.sp:    movea.l a5,a1
        adda.l  d7,a1
        move.l  d7,d1                       ; stack not in the file (Ace32
        sub.l   #$2000-1,d1                 ; saves 2000-7FFF only, also
        cmp.l   snap_len,d1                 ; with more RAM): its snapshots
        bcs.s   .spok                       ; are taken in the ROM's main
        cmp.l   #65536,d7                   ; loop, so the one return
        bcc.s   .spok                       ; address there is 04F7
        move.b  #$f7,(a1)
        move.b  #$04,1(a1)
.spok:
        SNAPW                               ; PC
        movea.l a5,a0
        adda.l  d0,a0
        move.l  a0,-(sp)
        SNAPW                               ; AF'
        move.b  d0,d7
        lsr.w   #8,d0
        move.b  d0,ST_A2(a6)
        move.b  d7,d0
        jsr     z80_to_f
        move.w  d3,ST_F2(a6)
        SNAPW
        move.w  d0,ST_BC2(a6)
        SNAPW
        move.w  d0,ST_DE2(a6)
        SNAPW
        move.w  d0,ST_HL2(a6)
        move.b  (a2),d0                     ; IM
        move.b  d0,ST_IM(a6)
        tst.b   4(a2)                       ; IFF1, IFF2
        sne     d0
        and.b   #1,d0
        move.b  d0,ST_IFF1(a6)
        tst.b   8(a2)
        sne     d0
        and.b   #1,d0
        move.b  d0,ST_IFF2(a6)
        move.b  12(a2),ST_I(a6)
        st      ST_REDRAW(a6)
        jsr     keys_up
        movea.l (sp)+,a0                    ; PC
        move.w  (sp)+,d0                    ; AF
        moveq   #0,d7
        move.w  d0,d7
        lsr.w   #8,d7
        jsr     z80_to_f
        movea.w ram_last,a3
        lea     slot_base+$8000,a4          ; slot_mid
        NEXT

; copy 1K from (a0) to (a1)+
.k1:    move.w  #255,d0
.kl:    move.l  (a0)+,(a1)+
        dbra    d0,.kl
        rts
