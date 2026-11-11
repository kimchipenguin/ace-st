; ---------------------------------------------------------------------------
; Settings dialog (Undo), from ACE.RSC (tools/mkrsc.py, object numbers in
; rsc.i), and the parameters file ACE.INF.
;
; Own event loop instead of form_do, so that keys work on every TOS:
;   1-4            RAM 3K / 19K / 35K / 51K
;   cursor keys    define the joystick's up / down / left / right key,
;   Insert         ... the fire key (then press the Ace key; Undo cancels)
;   T  Load Tape   S  Load Snapshot   R  Reset Ace   Q, Control+Q  Quit
;   L  Load Parameters   W  Save Parameters
;   Return, Enter, Undo  Continue
; A new RAM size takes a reset: Reset uses it; Continue asks.
;
; ACE.INF (text, in the start directory, read at start too):
;   RAM 19K
;   JOYSTICK 7 6 5 8 0        (up down left right fire, Ace key names)
; GPL v2 or later.
; ---------------------------------------------------------------------------

        include "rsc.i"

OBSIZE  equ 24                              ; AES object: state +10, spec +12
DLG_CONT  equ 0                             ; dialog results
DLG_RESET equ 1
DLG_SNAP  equ 2

; host_service (supervisor, all registers saved).  d0.w = DLG_CONT,
; DLG_RESET (new RAM size in ram_last) or DLG_SNAP (snap_buf filled).
; Quit sets quit_flag.
dialog:
        clr.b   dlg_req
        clr.w   dlg_result
        jsr     gem_enter
        bne     .leave
        tst.l   rsc_tree
        bne.s   .have
        move.l  #rscname,aes_addrin         ; rsrc_load
        move.w  #110,d0
        move.l  #$00000001,d1
        moveq   #1,d2
        jsr     aes_op
        tst.w   aes_intout
        bne.s   .ld
        lea     al_norsc,a0
        jsr     alert
        bra     .leave
.ld:    clr.w   aes_intin                   ; rsrc_gaddr(R_TREE, DIALOG)
        move.w  #DIALOG,aes_intin+2
        bsr     rs_gaddr
        move.l  d0,rsc_tree
.have:  bsr     dlg_get                     ; current settings
        move.b  dlg_ram,dlg_ram0
        bsr     dlg_set
        move.w  #1,aes_intin                ; wind_update(BEG_UPDATE)
        move.w  #107,d0
        move.l  #$00010001,d1
        moveq   #0,d2
        jsr     aes_op
        move.l  rsc_tree,aes_addrin         ; form_center
        move.w  #54,d0
        move.l  #$00000005,d1
        moveq   #1,d2
        jsr     aes_op
        movem.w aes_intout+2,d0-d3
        movem.w d0-d3,dlg_x
        clr.w   d0                          ; form_dial(FMD_START)
        bsr     dlg_dial
        bsr     dlg_draw

.loop:  lea     aes_intin,a0                ; evnt_multi(KEYBD | BUTTON,
        move.w  #3,(a0)+                    ; 1 click, left, down)
        move.w  #1,(a0)+
        move.w  #1,(a0)+
        move.w  #1,(a0)+
        moveq   #11,d0
.cl:    clr.w   (a0)+
        dbra    d0,.cl
        move.l  #msgbuf,aes_addrin
        move.w  #25,d0
        move.l  #$00100007,d1
        moveq   #1,d2
        jsr     aes_op
        move.w  aes_intout,d0
        btst    #0,d0
        beq.s   .mouse
        move.w  aes_intout+10,d0            ; key: scancode -> object
        lsr.w   #8,d0
        lea     dlg_keys,a0
.k:     move.b  (a0)+,d1
        beq     .loop
        move.b  (a0)+,d2
        cmp.b   d1,d0
        bne.s   .k
        moveq   #0,d0
        move.b  d2,d0
        moveq   #0,d7                       ; d7 = 0: by key
        bra.s   .obj
.mouse: btst    #1,d0
        beq     .loop
        clr.w   aes_intin                   ; objc_find(tree, 0, 8, x, y)
        move.w  #8,aes_intin+2
        move.l  aes_intout+2,aes_intin+4
        move.l  rsc_tree,aes_addrin
        move.w  #43,d0
        move.l  #$00040001,d1
        moveq   #1,d2
        jsr     aes_op
        move.w  aes_intout,d0
        bmi     .rel
        moveq   #1,d7                       ; d7 = 1: by mouse

.obj:   move.w  d0,d6                       ; d6 = object
        cmp.w   #D_RAM1,d6
        bcs.s   .nram
        cmp.w   #D_RAM4,d6
        bhi.s   .nram
        sub.w   #D_RAM1,d0
        move.b  d0,dlg_ram
        bsr     dlg_set
        move.w  #D_RAMBOX,d0
        bsr     dlg_obj
        bra     .rel
.nram:  lea     joy_objs,a0                 ; joystick boxes
        moveq   #4,d1
.jo:    cmp.b   (a0,d1.w),d6
        beq     .joy
        dbra    d1,.jo
        movea.l rsc_tree,a0                 ; exit buttons
        move.w  d6,d0
        mulu    #OBSIZE,d0
        btst    #2,9(a0,d0.l)               ; EXIT flag
        beq     .rel
        tst.b   d7
        beq.s   .bykey
        move.w  d6,aes_intin+2              ; graf_watchbox(tree, obj,
        clr.w   aes_intin                   ; SELECTED, NORMAL)
        move.w  #1,aes_intin+4
        clr.w   aes_intin+6
        move.l  rsc_tree,aes_addrin
        move.w  #75,d0
        move.l  #$00040001,d1
        moveq   #1,d2
        jsr     aes_op
        tst.w   aes_intout
        beq     .loop
        bra.s   .act
.bykey: move.w  d6,d0                       ; key: show it pressed
        moveq   #1,d1
        bsr     dlg_state

.act:   cmp.w   #D_CONT,d6
        beq     .close
        cmp.w   #D_RESET,d6
        bne.s   .nrs
        move.w  #DLG_RESET,dlg_result
        bra     .close
.nrs:   cmp.w   #D_QUIT,d6
        bne.s   .nq
        st      quit_flag
        bra     .close
.nq:    cmp.w   #D_TAPE,d6
        bne.s   .nt
        jsr     tape_pick
        beq     .close                      ; new tape: back to the Ace
        bsr     dlg_full
        bra     .redraw
.nt:    cmp.w   #D_SNAP,d6
        bne.s   .ns
        lea     snap_mask,a0
        lea     snap_title,a1
        jsr     fsel
        bne     .sno
        lea     fs_full,a0
        jsr     snap_read
        tst.l   d0
        bne.s   .serr
        move.w  #DLG_SNAP,dlg_result
        bra     .close
.serr:  move.l  d0,-(sp)
        bsr     dlg_full
        move.l  (sp)+,d0
        moveq   #AL_NOFILE,d1
        cmp.l   #-1,d0
        beq.s   .sal
        moveq   #AL_NOSNAP,d1
        cmp.l   #-2,d0
        beq.s   .sal
        moveq   #AL_NOMEM,d1
.sal:   move.w  d1,d0
        bsr     rs_alert
        bra     .redraw
.sno:   bsr     dlg_full
        bra     .redraw
.ns:    cmp.w   #D_LOADP,d6
        bne.s   .nl
        bsr     inf_load
        beq.s   .lok
        moveq   #AL_INFLOAD,d0
        bsr     rs_alert
.lok:   bsr     dlg_set
        bra     .redraw
.nl:    cmp.w   #D_SAVEP,d6
        bne     .rel
        bsr     inf_save
        beq.s   .redraw
        moveq   #AL_INFSAVE,d0
        bsr     rs_alert
.redraw:
        move.w  d6,d0                       ; button up again, all drawn
        moveq   #0,d1
        bsr     dlg_setst
        bsr     dlg_draw
        bra     .loop

; joystick box d1 (0 up, 1 down, 2 left, 3 right, 4 fire): select it, wait
; for an Ace key (Undo cancels, keys without an Ace key are ignored)
.joy:   move.w  d1,d5
        move.w  d6,d0
        moveq   #1,d1
        bsr     dlg_state
        movea.l rsc_tree,a0                 ; hint: "Press a key"
        move.l  D_HINT*OBSIZE+12(a0),-(sp)
        move.w  #FS_PRESS,d0
        bsr     rs_free
        movea.l rsc_tree,a0
        move.l  d0,D_HINT*OBSIZE+12(a0)
        move.w  #D_HINT,d0
        bsr     dlg_obj
        tst.b   d7
        beq.s   .jk
        bsr     wait_up
.jk:    move.w  #20,d0                      ; evnt_keybd
        move.l  #$00000001,d1
        moveq   #0,d2
        jsr     aes_op
        move.w  aes_intout,d0
        lsr.w   #8,d0
        cmp.w   #$61,d0                     ; Undo
        beq.s   .jend
        cmp.w   #128,d0
        bcc.s   .jk
        lea     keyname,a0
        move.w  d0,d1
        lsl.w   #2,d1
        tst.b   (a0,d1.w)
        beq.s   .jk
        lea     dlg_joy,a0
        move.b  d0,(a0,d5.w)
        bsr     dlg_set
.jend:  movea.l rsc_tree,a0
        move.l  (sp)+,D_HINT*OBSIZE+12(a0)
        move.w  #D_HINT,d0
        bsr     dlg_obj
        move.w  d6,d0
        moveq   #0,d1
        bsr     dlg_state
        bra     .loop

.rel:   tst.b   d7                          ; clicked: wait for the release
        beq     .loop
        bsr     wait_up
        bra     .loop

.close: move.b  dlg_ram,d0                  ; a new RAM size?
        cmp.b   dlg_ram0,d0
        beq.s   .cls
        cmp.w   #DLG_CONT,dlg_result
        bne.s   .cls                        ; Reset: takes it; snapshot: its own
        tst.b   quit_flag
        bne.s   .cls
        moveq   #AL_RAM,d0
        bsr     rs_alert
        cmp.w   #1,d0
        bne.s   .keep
        move.w  #DLG_RESET,dlg_result
        bra.s   .cls
.keep:  move.b  dlg_ram0,dlg_ram
.cls:   moveq   #3,d0                       ; form_dial(FMD_FINISH)
        bsr     dlg_dial
        clr.w   aes_intin                   ; wind_update(END_UPDATE)
        move.w  #107,d0
        move.l  #$00010001,d1
        moveq   #0,d2
        jsr     aes_op
        move.w  d6,d0                       ; button state back to normal
        moveq   #0,d1
        bsr     dlg_setst
        bsr     dlg_put                     ; settings take effect
.leave: jsr     gem_leave
        move.w  dlg_result,d0
        rts

; wait until the mouse button is up: evnt_button(1, 1, 0)
wait_up:
        move.w  #1,aes_intin
        move.w  #1,aes_intin+2
        clr.w   aes_intin+4
        move.w  #21,d0
        move.l  #$00030005,d1
        moveq   #0,d2
        jmp     aes_op

; form_dial(d0.w, dialog rectangle twice)
dlg_dial:
        lea     aes_intin,a0
        move.w  d0,(a0)+
        movem.w dlg_x,d0-d3
        movem.w d0-d3,(a0)
        movem.w d0-d3,8(a0)
        move.w  #51,d0
        move.l  #$00090001,d1
        moveq   #0,d2
        jmp     aes_op

; after the file selector (the desktop draws its pattern where it was):
; the screen black again, the dialog on it
dlg_full:
        move.w  #256,aes_intin              ; graf_mouse(M_OFF)
        move.w  #78,d0
        move.l  #$00010001,d1
        moveq   #1,d2
        jsr     aes_op
        movea.l scr_ptr,a0
        moveq   #-1,d1
        move.w  #(32000/4)-1,d0
.clr:   move.l  d1,(a0)+
        dbra    d0,.clr
        bsr.s   dlg_draw
        move.w  #257,aes_intin              ; graf_mouse(M_ON)
        move.w  #78,d0
        move.l  #$00010001,d1
        moveq   #1,d2
        jmp     aes_op

; draw the whole dialog
dlg_draw:
        moveq   #0,d0
        movem.w dlg_x,d1-d4
        bra.s   objc_draw

; redraw object d0.w: the tree from the root, clipped to the object (and
; 3 pixels around it for the borders of exit buttons)
dlg_obj:
        move.w  d0,aes_intin                ; objc_offset
        move.l  rsc_tree,aes_addrin
        move.w  d0,-(sp)
        move.w  #44,d0
        move.l  #$00010003,d1
        moveq   #1,d2
        jsr     aes_op
        move.w  (sp)+,d0
        movea.l rsc_tree,a0
        mulu    #OBSIZE,d0
        movem.w 20(a0,d0.l),d3-d4           ; w, h
        movem.w aes_intout+2,d1-d2          ; x, y
        subq.w  #3,d1
        subq.w  #3,d2
        addq.w  #6,d3
        addq.w  #6,d4
        moveq   #0,d0
; objc_draw(tree, d0 = start, 8, clip d1-d4)
objc_draw:
        lea     aes_intin,a0
        move.w  d0,(a0)+
        move.w  #8,(a0)+
        movem.w d1-d4,(a0)
        move.l  rsc_tree,aes_addrin
        move.w  #42,d0
        move.l  #$00060001,d1
        moveq   #1,d2
        jmp     aes_op

; object d0.w state SELECTED (d1 = 1) or NORMAL (d1 = 0), redrawn
dlg_state:
        move.w  d0,-(sp)
        bsr.s   dlg_setst
        move.w  (sp)+,d0
        bra.s   dlg_obj

dlg_setst:
        movea.l rsc_tree,a0
        mulu    #OBSIZE,d0
        bclr    #0,11(a0,d0.l)
        tst.w   d1
        beq.s   .n
        bset    #0,11(a0,d0.l)
.n:     rts

; rsrc_gaddr(aes_intin[0] type, aes_intin[1] index); d0.l = address
rs_gaddr:
        move.w  #112,d0
        move.l  #$00020001,d1
        move.l  #$00010000,d2
        jsr     aes_op
        move.l  aes_addrout,d0
        rts

; free string d0.w -> d0.l
rs_free:
        move.w  #15,aes_intin               ; R_FRSTR: the address of the
        move.w  d0,aes_intin+2              ; string's pointer
        bsr.s   rs_gaddr
        movea.l d0,a0
        move.l  (a0),d0
        rts

; alert from free string d0.w; d0.w = button
rs_alert:
        bsr.s   rs_free
        movea.l d0,a0
        jmp     alert

; settings -> dlg_ram / dlg_joy
dlg_get:
        move.w  ram_last,d0
        rol.w   #2,d0
        and.b   #3,d0
        move.b  d0,dlg_ram
        lea     joy_map,a0
        lea     dlg_joy,a1
        bra.s   copy5

; dlg_ram / dlg_joy -> settings
dlg_put:
        moveq   #0,d0
        move.b  dlg_ram,d0
        ror.w   #2,d0
        or.w    #$3fff,d0
        move.w  d0,ram_last
        lea     dlg_joy,a0
        lea     joy_map,a1
; 5 bytes (a0) -> (a1)
copy5:  moveq   #4,d0
.c:     move.b  (a0)+,(a1)+
        dbra    d0,.c
        rts

; dlg_ram / dlg_joy -> the objects (RAM buttons, joystick key names)
dlg_set:
        movea.l rsc_tree,a0
        moveq   #3,d0
.r:     move.w  d0,d1
        add.w   #D_RAM1,d1
        mulu    #OBSIZE,d1
        bclr    #0,11(a0,d1.l)
        cmp.b   dlg_ram,d0
        bne.s   .rn
        bset    #0,11(a0,d1.l)
.rn:    dbra    d0,.r
        lea     joy_objs,a1
        lea     dlg_joy,a2
        moveq   #4,d0
.j:     moveq   #0,d1
        move.b  (a1,d0.w),d1
        mulu    #OBSIZE,d1
        movea.l 12(a0,d1.l),a3              ; the button's text
        moveq   #0,d1
        move.b  (a2,d0.w),d1
        lsl.w   #2,d1
        lea     keyname,a4
        adda.w  d1,a4
        move.b  (a4)+,(a3)+
        move.b  (a4)+,(a3)+
        move.b  (a4)+,(a3)+
        clr.b   (a3)
        dbra    d0,.j
        rts

; ---------------------------------------------------------------------------
; ACE.INF
; ---------------------------------------------------------------------------

; start: settings from ACE.INF when there is one
inf_start:
        bsr     dlg_get
        bsr.s   inf_load
        bne.s   .no
        bra     dlg_put
.no:    rts

; read ACE.INF into dlg_ram / dlg_joy; d0 = 0 (Z) when read
inf_load:
        movem.l d3-d7/a3-a6,-(sp)
        clr.w   -(sp)                       ; Fopen, read
        pea     infname
        move.w  #$3d,-(sp)
        trap    #1
        addq.l  #8,sp
        tst.l   d0
        bmi     .err
        move.w  d0,d6
        pea     rd_buf
        move.l  #RDBUF-1,-(sp)
        move.w  d6,-(sp)
        move.w  #$3f,-(sp)                  ; Fread
        trap    #1
        lea     12(sp),sp
        move.l  d0,d7
        move.w  d6,-(sp)
        move.w  #$3e,-(sp)                  ; Fclose
        trap    #1
        addq.l  #4,sp
        tst.l   d7
        bmi     .err
        lea     rd_buf,a5                   ; a5 = text
        clr.b   (a5,d7.l)
.next:  bsr     inf_token
        beq     .ok
        lea     tok_ram,a1
        bsr     tok_cmp
        bne.s   .nram
        bsr     inf_token                   ; RAM <n>K
        beq     .ok
        lea     tokbuf,a0
        moveq   #0,d0
.num:   moveq   #0,d1
        move.b  (a0)+,d1
        sub.b   #'0',d1
        bcs.s   .numd
        cmp.b   #9,d1
        bhi.s   .numd
        mulu    #10,d0
        add.w   d1,d0
        bra.s   .num
.numd:  lea     ram_sizes,a0
        moveq   #3,d1
.rs:    cmp.b   (a0,d1.w),d0
        beq.s   .rsok
        dbra    d1,.rs
        bra.s   .next
.rsok:  move.b  d1,dlg_ram
        bra.s   .next
.nram:  lea     tok_joy,a1
        bsr     tok_cmp
        bne.s   .next
        moveq   #0,d5                       ; JOYSTICK <5 key names>
.jn:    bsr     inf_token
        beq.s   .ok
        lea     keyname,a2                  ; find the name
        moveq   #0,d4
.kn:    lea     tokbuf,a0
        movea.l a2,a1
        moveq   #2,d1
.kc:    move.b  (a1)+,d0
        cmp.b   #' ',d0
        beq.s   .ks
        cmp.b   (a0)+,d0
        bne.s   .kno
.ks:    dbra    d1,.kc
        tst.b   (a2)                        ; empty entry
        beq.s   .kno
        tst.b   (a0)                        ; whole token used
        bne.s   .kno
        lea     dlg_joy,a0
        move.b  d4,(a0,d5.w)
        bra.s   .kd
.kno:   addq.l  #4,a2
        addq.w  #1,d4
        cmp.w   #128,d4
        bcs.s   .kn
.kd:    addq.w  #1,d5
        cmp.w   #5,d5
        bcs.s   .jn
        bra     .next
.ok:    moveq   #0,d0
        bra.s   .ret
.err:   moveq   #-1,d0
.ret:   movem.l (sp)+,d3-d7/a3-a6
        tst.l   d0
        rts

; next word of (a5)+ into tokbuf (upper case, max 15); Z when none
inf_token:
.sk:    move.b  (a5),d0
        beq.s   .none
        cmp.b   #' ',d0
        bhi.s   .w
        addq.l  #1,a5
        bra.s   .sk
.w:     lea     tokbuf,a0
        moveq   #15,d1
.wc:    move.b  (a5),d0
        cmp.b   #' ',d0
        bls.s   .we
        addq.l  #1,a5
        cmp.b   #'a',d0
        bcs.s   .up
        cmp.b   #'z',d0
        bhi.s   .up
        sub.b   #32,d0
.up:    tst.w   d1
        beq.s   .wc
        move.b  d0,(a0)+
        subq.w  #1,d1
        bra.s   .wc
.we:    clr.b   (a0)
        moveq   #1,d0
        rts
.none:  moveq   #0,d0
        rts

; tokbuf = string (a1)?  Z when equal
tok_cmp:
        lea     tokbuf,a0
.c:     move.b  (a1)+,d0
        cmp.b   (a0)+,d0
        bne.s   .ne
        tst.b   d0
        bne.s   .c
.ne:    rts

; write ACE.INF from dlg_ram / dlg_joy; d0 = 0 (Z) when saved
inf_save:
        movem.l d3-d7/a3-a6,-(sp)
        lea     rd_buf,a0
        lea     tok_ram,a1
        bsr     .str
        move.b  #' ',(a0)+
        moveq   #0,d0
        move.b  dlg_ram,d0
        lea     ram_sizes,a1
        move.b  (a1,d0.w),d0
        divu    #10,d0
        tst.w   d0
        beq.s   .one
        add.b   #'0',d0
        move.b  d0,(a0)+
.one:   swap    d0
        add.b   #'0',d0
        move.b  d0,(a0)+
        move.b  #'K',(a0)+
        move.b  #13,(a0)+
        move.b  #10,(a0)+
        lea     tok_joy,a1
        bsr     .str
        lea     dlg_joy,a2
        moveq   #4,d2
.j:     move.b  #' ',(a0)+
        moveq   #0,d0
        move.b  (a2)+,d0
        lsl.w   #2,d0
        lea     keyname,a1
        adda.w  d0,a1
        moveq   #2,d1
.jc:    move.b  (a1)+,d0
        beq.s   .jn
        cmp.b   #' ',d0
        beq.s   .jn
        move.b  d0,(a0)+
.jn:    dbra    d1,.jc
        dbra    d2,.j
        move.b  #13,(a0)+
        move.b  #10,(a0)+
        move.l  a0,d7
        sub.l   #rd_buf,d7                  ; d7 = length
        clr.w   -(sp)                       ; Fcreate
        pea     infname
        move.w  #$3c,-(sp)
        trap    #1
        addq.l  #8,sp
        tst.l   d0
        bmi.s   .err
        move.w  d0,d6
        pea     rd_buf
        move.l  d7,-(sp)
        move.w  d6,-(sp)
        move.w  #$40,-(sp)                  ; Fwrite
        trap    #1
        lea     12(sp),sp
        move.l  d0,d5
        move.w  d6,-(sp)
        move.w  #$3e,-(sp)                  ; Fclose
        trap    #1
        addq.l  #4,sp
        cmp.l   d7,d5
        bne.s   .err
        moveq   #0,d0
        bra.s   .ret
.err:   moveq   #-1,d0
.ret:   movem.l (sp)+,d3-d7/a3-a6
        tst.l   d0
        rts
.str:   move.b  (a1)+,(a0)+
        bne.s   .str
        subq.l  #1,a0
        rts

ram_sizes:
        dc.b    3,19,35,51
joy_objs:
        dc.b    D_JUP,D_JDOWN,D_JLEFT,D_JRIGHT,D_JFIRE
dlg_keys:                                   ; scancode, object; 0 = end
        dc.b    $1c,D_CONT,$72,D_CONT,$61,D_CONT
        dc.b    $02,D_RAM1,$03,D_RAM2,$04,D_RAM3,$05,D_RAM4
        dc.b    $48,D_JUP,$50,D_JDOWN,$4b,D_JLEFT,$4d,D_JRIGHT,$52,D_JFIRE
        dc.b    $14,D_TAPE,$1f,D_SNAP,$13,D_RESET,$10,D_QUIT
        dc.b    $26,D_LOADP,$11,D_SAVEP
        dc.b    0
tok_ram:  dc.b  "RAM",0
tok_joy:  dc.b  "JOYSTICK",0
infname:  dc.b  "ACE.INF",0
rscname:  dc.b  "ACE.RSC",0
al_norsc: dc.b  "[1][ACE.RSC is missing.][ OK ]",0
        even
