; ---------------------------------------------------------------------------
; ACE-ST: Jupiter Ace emulator for the Atari ST
; Program entry, system setup, interrupt handlers, data.
;
; Build:  make   (vasm, Motorola syntax, -Ftos)
; Needs:  ACE.ROM (8192 bytes, included, see ROM.md) in the current
;         directory, ST high (mono) or ST medium.
; Keys:   Control+Q quits, Control+O picks the tape file (GEM file selector),
;         Help shows the Ace keyboard (any key or click goes back), Undo
;         or a left click the settings, Alt+T saves a screenshot (.DOO).
; GPL v2 or later.
; ---------------------------------------------------------------------------

        include "macros.s"

        section text,code

start:
        movea.l 4(sp),a0                    ; basepage
        lea     mystack_top,sp
        lea     $81(a0),a1                  ; command line: a file name
        moveq   #0,d1
        move.b  $80(a0),d1
        lea     arg_name,a2
        moveq   #126,d2
        bra.s   .arg
.argl:  move.b  (a1)+,d0
        cmp.b   #' ',d0
        bls.s   .arg
        move.b  d0,(a2)+
        subq.w  #1,d2
        beq.s   .arge
.arg:   dbra    d1,.argl
.arge:  clr.b   (a2)
        ifd     ARGTEST                     ; test build: command line
        lea     argtest,a1                  ; SNAP.ACE (Hatari's autostart
        lea     arg_name,a2                 ; cannot pass one)
.argc:  move.b  (a1)+,(a2)+
        bne.s   .argc
        endif
        move.l  $c(a0),d0                   ; text+data+bss+basepage
        add.l   $14(a0),d0
        add.l   $1c(a0),d0
        add.l   #$100,d0
        move.l  d0,-(sp)
        move.l  a0,-(sp)
        clr.w   -(sp)
        move.w  #$4a,-(sp)                  ; Mshrink
        trap    #1
        lea     12(sp),sp
        clr.l   -(sp)
        move.w  #$20,-(sp)                  ; Super
        trap    #1
        addq.l  #6,sp
        move.l  d0,old_ssp

        move.w  #4,-(sp)                    ; Getrez
        trap    #14
        addq.l  #2,sp
        cmp.w   #2,d0
        beq.s   .mono
        cmp.w   #1,d0
        beq.s   .med
        pea     msg_rez
        bra     fail
.med:   st      medium
        lea     $ffff8240.w,a0              ; keep the desktop colours
        lea     old_pal,a1
        moveq   #3,d0
.spal:  move.w  (a0)+,(a1)+
        dbra    d0,.spal
.mono:
        move.w  #2,-(sp)                    ; Physbase
        trap    #14
        addq.l  #2,sp
        move.l  d0,scr_ptr

        clr.w   -(sp)                       ; Fopen ACE.ROM, read
        pea     romname
        move.w  #$3d,-(sp)
        trap    #1
        addq.l  #8,sp
        tst.l   d0
        bpl.s   .rom
        pea     msg_rom
        bra     fail
.rom:
        move.w  d0,d4
        pea     mem
        move.l  #8192,-(sp)
        move.w  d4,-(sp)
        move.w  #$3f,-(sp)                  ; Fread
        trap    #1
        lea     12(sp),sp
        cmp.l   #8192,d0
        beq.s   .romok
        pea     msg_rom
        bra     fail
.romok:
        move.w  d4,-(sp)
        move.w  #$3e,-(sp)                  ; Fclose
        trap    #1
        addq.l  #4,sp

        move.w  #$ffff,ram_last             ; 51K (all 48K of expansion)
        jsr     inf_start                   ; or what ACE.INF says

        ; tape traps: ED FC C9 at 18A7 (load), ED FD C9 at 1820 (save)
        lea     mem,a0
        move.b  #$ed,$18a7(a0)
        move.b  #$fc,$18a8(a0)
        move.b  #$c9,$18a9(a0)
        move.b  #$ed,$1820(a0)
        move.b  #$fd,$1821(a0)
        move.b  #$c9,$1822(a0)
        ; native keyboard scan: ED FE C9 at 0336 (see kb_scan);
        ; -DNOKBSCAN keeps the ROM one (for speed comparisons)
        ifnd NOKBSCAN
        move.b  #$ed,$0336(a0)
        move.b  #$fe,$0337(a0)
        move.b  #$c9,$0338(a0)
        endif
        ; native Forth checks + NEXT: ED FF at 04C8 (see forth_next);
        ; -DNOFNEXT keeps the ROM code
        ifnd NOFNEXT
        move.b  #$ed,$04c8(a0)
        move.b  #$ff,$04c9(a0)
        endif
        ; native Forth data stack pop of BC: ED FB at 084E (see ds_popbc)
        move.b  #$ed,$084e(a0)
        move.b  #$fb,$084f(a0)
        ; BEEP on the YM2149: ED FA at 0BAF (see beep); -DNOSOUND keeps
        ; the ROM loop (silent)
        ifnd NOSOUND
        move.b  #$ed,$0baf(a0)
        move.b  #$fa,$0bb0(a0)
        endif

        jsr     keys_up
        move.w  #-1,tape_fh

        ; command line file: a snapshot starts at once, anything else is
        ; the tape
        tst.b   arg_name
        beq.s   .noarg
        lea     arg_name,a0
        jsr     snap_read
        tst.l   d0
        beq.s   .noarg
        lea     arg_name,a0
        lea     tapename,a1
.argt:  move.b  (a0)+,(a1)+
        bne.s   .argt
.noarg:
        move.b  #4,tc_div
        st      state+ST_REDRAW

        ; no cursor, no mouse
        clr.w   -(sp)                       ; Cursconf(0 = hide, 0)
        clr.w   -(sp)
        move.w  #21,-(sp)
        trap    #14
        addq.l  #6,sp
        dc.w    $a00a                       ; Line-A hide mouse
        jsr     build_expand

        ; interrupts: Timer C (200 Hz -> 50 Hz) and IKBD
        move.w  sr,-(sp)
        move.w  #$2700,sr
        move.l  $114.w,old_timerc
        move.l  #timerc_isr,$114.w
        move.l  $118.w,old_ikbd
        move.l  #ikbd_isr,$118.w
        move.w  (sp)+,sr
        move.b  #$12,d0                     ; IKBD: disable mouse (its buttons
        bsr     ikbd_send                   ; are then the fire buttons: left
        move.b  #$14,d0                     ; = port 0, opens the dialog,
        bsr     ikbd_send                   ; right = port 1), joystick events

        ; startup screen: the Jupiter Ace logo for 2 s (a key skips it)
        move.w  #(400-LOGO_H)/2,d0
        tst.b   medium
        beq.s   .slogo
        move.w  #(200-LOGOM_H)/2,d0
.slogo: jsr     draw_logo
        clr.b   any_key
        move.l  $4ba.w,d1                   ; _hz_200
        add.l   #400,d1
.splash:
        tst.b   quit_flag
        bne     shutdown
        tst.b   any_key
        bne.s   .spl_end
        cmp.l   $4ba.w,d1
        bhi.s   .splash
.spl_end:
        jsr     keys_up                     ; forget keys pressed meanwhile
        clr.b   help_req
        clr.b   open_flag
        movea.l scr_ptr,a0                  ; black screen for the Ace
        move.w  #(32000/4)-1,d0
.clr:   move.l  #-1,(a0)+
        dbra    d0,.clr
        jsr     pal_ace

        ifd     TRACE
        move.l  #TRACE*18,-(sp)
        move.w  #$48,-(sp)                  ; Malloc
        trap    #1
        addq.l  #6,sp
        move.l  d0,trace_buf
        bne.s   .tbuf
        pea     msg_mem
        bra     fail
.tbuf:  move.l  d0,trace_ptr
        add.l   #TRACE*18,d0
        move.l  d0,trace_end
        move.l  #trace_ev,trace_evp
        move.l  #trace_in,trace_inp
        endif

        ifnd    NONATIVE
        jsr     native_init
        endif
        tst.l   snap_buf                    ; snapshot from the command line
        beq.s   z80_reset
        jmp     snap_start

; Z80 reset, as at power on: everything above the ROM reads $FF (like xAce;
; also where there is no RAM), the machine state cleared, PC = 0, a3 = last
; RAM address from ram_last.  Also the settings dialog's Reset (and RAM
; size change): the stack starts again at the top.
z80_reset:
        lea     mystack_top,sp
        lea     mem+8192,a0
        move.w  #(57344/4)-1,d0
.fill:  move.l  #-1,(a0)+
        dbra    d0,.fill
        lea     state,a6
        moveq   #ST_SIZE-1,d0
.st:    clr.b   (a6,d0.w)
        dbra    d0,.st
        st      ST_REDRAW(a6)
        jsr     keys_up
        movea.w ram_last,a3
        lea     mem,a5
        lea     slot_base+$8000,a4          ; slot_mid
        movea.l a5,a0                       ; PC = 0
        movea.l a5,a1
        adda.l  #65536,a1                   ; SP = 0
        moveq   #0,d3
        moveq   #0,d4
        moveq   #0,d5
        moveq   #0,d6
        moveq   #0,d7
        NEXT

; fatal message (pea already pushed), wait for a key, exit
fail:
        move.w  #9,-(sp)                    ; Cconws
        trap    #1
        addq.l  #6,sp
        move.w  #8,-(sp)                    ; Cnecin
        trap    #1
        addq.l  #2,sp
        bra.s   leave

shutdown:
        jsr     beep_off
        jsr     pal_tos
.rel:   tst.b   ctrl_down                   ; wait until Control and Q are up,
        bne.s   .rel                        ; so no key reaches the desktop
        tst.b   q_down
        bne.s   .rel
        move.w  #$2700,sr
        move.l  old_timerc,$114.w
        move.l  old_ikbd,$118.w
        move.w  #$2000,sr
        move.b  #$14,d0                     ; IKBD: joystick events, then the
        bsr     ikbd_send                   ; mouse (a joystick mode command
        move.b  #$08,d0                     ; turns the mouse off)
        bsr     ikbd_send
        jsr     tape_close
.flush: move.w  #2,-(sp)                    ; drop keys TOS still has
        move.w  #1,-(sp)                    ; Bconstat(CON)
        trap    #13
        addq.l  #4,sp
        tst.w   d0
        beq.s   .flushed
        move.w  #2,-(sp)
        move.w  #2,-(sp)                    ; Bconin(CON)
        trap    #13
        addq.l  #4,sp
        bra.s   .flush
.flushed:
        dc.w    $a009                       ; Line-A show mouse (the text
leave:                                      ; cursor stays off for the desktop)
        move.l  old_ssp,-(sp)
        move.w  #$20,-(sp)                  ; Super (back to user mode)
        trap    #1
        clr.w   -(sp)                       ; Pterm0
        trap    #1

; called from do_int every 20 ms with the Z80 registers live: save everything
host_service:
        movem.l d0-d7/a0-a6,-(sp)
        tst.b   dlg_req
        beq.s   .nd
        jsr     dialog                      ; Undo: settings
        subq.w  #DLG_RESET,d0
        beq     z80_reset
        subq.w  #DLG_SNAP-DLG_RESET,d0
        bne.s   .dc
        jmp     snap_start
.dc:    jsr     refresh_screen
        movem.l (sp),d0-d7/a0-a6
.nd:    tst.b   help_req
        beq.s   .nh
        jsr     help_show                   ; Help: keyboard picture
        jsr     refresh_screen
        movem.l (sp),d0-d7/a0-a6
.nh:    tst.b   quit_flag
        bne     shutdown
        tst.b   open_flag
        beq.s   .no
        jsr     tape_select                 ; Control+O
        jsr     refresh_screen
        movem.l (sp),d0-d7/a0-a6
.no:    tst.b   shot_req
        beq.s   .ns
        clr.b   shot_req
        jsr     refresh_screen
        movem.l (sp),d0-d7/a0-a6
        jsr     screenshot                  ; Alt+T
        movem.l (sp),d0-d7/a0-a6
.ns:
        ifd     JOYTEST                     ; test build: joy_port poked by
        jsr     joy_update                  ; the Hatari debugger
        endif
        addq.b  #1,svc_tick
        ifd     ICOUNT
        addq.l  #1,iframes
        endif
        move.b  svc_tick,d0
        and.b   #3,d0
        bne.s   .nr
        jsr     refresh_screen              ; ~12.5 Hz like xAce
.nr:    movem.l (sp)+,d0-d7/a0-a6
        rts

; Alt+T: save the screen as ACE_nnnn.DOO (Doodle: 32000 bytes, 640x400
; mono, 1 = black) in the current directory, the first number not used
; yet; a bell when saved.  ST medium: plane 0 holds the picture (1 =
; black), each line is written twice.
screenshot:
        lea     shot_buf,a1
        movea.l scr_ptr,a0
        tst.b   medium
        bne.s   .med
        move.w  #32000/4-1,d0
.cp:    move.l  (a0)+,(a1)+
        dbra    d0,.cp
        bra.s   .name
.med:   move.w  #199,d0
.mline: moveq   #39,d1
.mw:    move.w  (a0),(a1)
        move.w  (a0),80(a1)
        addq.l  #4,a0
        addq.l  #2,a1
        dbra    d1,.mw
        lea     80(a1),a1
        dbra    d0,.mline
.name:  move.w  #$17,-(sp)                  ; Fsfirst: name in use?
        pea     shot_name
        move.w  #$4e,-(sp)
        trap    #1
        addq.l  #8,sp
        tst.l   d0
        bmi.s   .free
        lea     shot_name+8,a0              ; next number: ACE_nnnn
        moveq   #3,d1
.inc:   addq.b  #1,-(a0)
        cmp.b   #'9',(a0)
        bls.s   .name
        move.b  #'0',(a0)
        dbra    d1,.inc
        rts                                 ; all 9999 used
.free:  clr.w   -(sp)                       ; Fcreate
        pea     shot_name
        move.w  #$3c,-(sp)
        trap    #1
        addq.l  #8,sp
        tst.l   d0
        bmi.s   .ret
        move.w  d0,d7
        pea     shot_buf
        move.l  #32000,-(sp)
        move.w  d7,-(sp)
        move.w  #$40,-(sp)                  ; Fwrite
        trap    #1
        lea     12(sp),sp
        move.l  d0,d6
        move.w  d7,-(sp)
        move.w  #$3e,-(sp)                  ; Fclose
        trap    #1
        addq.l  #4,sp
        cmp.l   #32000,d6
        bne.s   .ret
        move.w  #7,-(sp)                    ; Bconout(CON, bell)
        move.w  #2,-(sp)
        move.w  #3,-(sp)
        trap    #13
        addq.l  #6,sp
.ret:   rts

; Help: show the Jupiter Ace logo and EightyOne's keyboard picture
; (512x223, 1 bit) on a white screen; the Ace stops until Help again
; (or Control+Q).
help_show:
        clr.b   help_req
        tst.b   medium
        beq.s   .mono
        move.w  #HELPM_Y,d0
        bsr     draw_logo
        movea.l scr_ptr,a1                  ; 512 pixels = 128 bytes, 64 in
        lea     KBPICM_Y*160+16(a1),a1
        lea     kbmed,a0
        move.w  #KBPICM_H-1,d0
.mrow:  moveq   #31,d1
.mcp:   move.l  (a0)+,(a1)+
        dbra    d1,.mcp
        lea     160-128(a1),a1
        dbra    d0,.mrow
        bra.s   .shown
.mono:  move.w  #HELP_Y,d0
        bsr     draw_logo
        movea.l scr_ptr,a1
        lea     KBPIC_Y*80+8(a1),a1
        lea     kbpic,a0
        move.w  #KBPIC_H-1,d0
.row:   moveq   #15,d1
.cp:    move.l  (a0)+,(a1)+
        dbra    d1,.cp
        lea     80-64(a1),a1
        dbra    d0,.row
.shown: clr.b   help_close
        st      help_on
.wait:  tst.b   quit_flag
        bne.s   .done
        tst.b   help_close
        beq.s   .wait
.done:  clr.b   help_on
        jsr     keys_up                     ; all Ace keys up
        movea.l scr_ptr,a0                  ; black screen, full redraw
        move.w  #(32000/4)-1,d0
.blk:   move.l  #-1,(a0)+
        dbra    d0,.blk
        bsr     pal_ace
        st      state+ST_REDRAW
        rts

KBPIC_H equ 223
HELP_Y  equ (400-LOGO_H-16-KBPIC_H)/2       ; logo, 16 lines gap, keyboard
KBPIC_Y equ HELP_Y+LOGO_H+16
KBPICM_H equ 112                            ; ST medium: half height
HELPM_Y equ (200-LOGOM_H-8-KBPICM_H)/2
KBPICM_Y equ HELPM_Y+LOGOM_H+8

; White screen with the Jupiter Ace logo (448x103, 1 bit; medium: 448x52,
; 4 shades with the picture palette) centred horizontally, top line in d0.w.
draw_logo:
        tst.b   medium
        bne.s   .med
        movea.l scr_ptr,a0
        movea.l a0,a1
        moveq   #0,d1
        move.w  #(32000/4)-1,d2
.clr:   move.l  d1,(a0)+
        dbra    d2,.clr
        mulu    #80,d0
        lea     (80-LOGO_W)/2(a1,d0.l),a1
        lea     logopic,a0
        move.w  #LOGO_H-1,d0
.row:   moveq   #LOGO_W/4-1,d1
.cp:    move.l  (a0)+,(a1)+
        dbra    d1,.cp
        lea     80-LOGO_W(a1),a1
        dbra    d0,.row
        rts
.med:   bsr     pal_pic
        movea.l scr_ptr,a0
        movea.l a0,a1
        moveq   #0,d1
        move.w  #(32000/4)-1,d2
.mclr:  move.l  d1,(a0)+
        dbra    d2,.mclr
        mulu    #160,d0
        lea     24(a1,d0.l),a1              ; 96 pixels in
        lea     logomed,a0
        move.w  #LOGOM_H-1,d0
.mrow:  moveq   #112/4-1,d1                 ; 448 pixels = 112 bytes
.mcp:   move.l  (a0)+,(a1)+
        dbra    d1,.mcp
        lea     160-112(a1),a1
        dbra    d0,.mrow
        rts

LOGO_W  equ 56                              ; bytes per line
LOGO_H  equ 103
LOGOM_H equ 52                              ; ST medium

; ST medium palettes (colours 0-3; nothing to do in mono).  pal_ace: the Ace
; screen is cleared to all ones and drawn in plane 0 only, so plane 1 stays
; set: colour 2 = white, 3 = black, like mono; colour 0 (the border) black.  pal_pic: 4 shades for the
; pictures, 0 = white .. 3 = black.  pal_tos: the desktop's colours.
pal_ace:
        lea     pals,a0
        bra.s   pal_set
pal_pic:
        lea     pals+8,a0
        bra.s   pal_set
pal_tos:
        lea     old_pal,a0
pal_set:
        tst.b   medium
        beq.s   .no
        move.l  (a0)+,$ffff8240.w
        move.l  (a0),$ffff8244.w
.no:    rts

; ---------------------------------------------------------------------------
; Interrupt handlers
; ---------------------------------------------------------------------------
timerc_isr:
        subq.b  #1,tc_div
        bne.s   .chain
        move.b  #4,tc_div
        st      state+ST_INT
.chain: move.l  old_timerc,-(sp)
        rts                                 ; into the TOS handler, which RTEs

ikbd_send:
.w:     btst    #1,$fffffc00.w              ; transmit ready?
        beq.s   .w
        move.b  d0,$fffffc02.w
        rts

ikbd_isr:
        movem.l d0-d3/a0-a2,-(sp)
.loop:  move.b  $fffffc00.w,d0
        btst    #0,d0                       ; receive data ready?
        beq     .done
        moveq   #0,d1
        move.b  $fffffc02.w,d1
        move.b  joy_hdr,d0
        beq.s   .nojoy
        clr.b   joy_hdr                     ; joystick packet: $FE/$FF, state
        and.w   #1,d0
        lea     joy_port,a0
        tst.b   help_on                     ; Help screen: fire (or a mouse
        beq.s   .jdlg                       ; button) closes it
        tst.b   d1
        bpl.s   .jst
        st      help_close
        bra.s   .jst
.jdlg:  tst.w   d0                          ; port 0 fire = left mouse button:
        bne.s   .jst                        ; the settings dialog (as Undo),
        tst.b   d1                          ; not passed to the Ace
        bpl.s   .jst
        st      dlg_req
        and.b   #$7f,d1
.jst:   move.b  d1,(a0,d0.w)
        bsr     joy_update
        bra.s   .loop
.nojoy: tst.b   ikbd_skip
        beq.s   .nopkt
        subq.b  #1,ikbd_skip                ; payload of another packet
        bra.s   .loop
.nopkt: cmp.b   #$f6,d1
        bcs     .key
        cmp.b   #$fe,d1
        bcs.s   .hdr
        move.b  d1,joy_hdr
        bra.s   .loop
.hdr:   sub.b   #$f6,d1                     ; packet header: bytes still to come
        lea     skiptab,a0
        move.b  (a0,d1.w),ikbd_skip
        bra     .loop
.key:   tst.b   d1                          ; any make code (startup screen)
        bmi.s   .kb
        st      any_key
.kb:    move.b  d1,d0
        and.b   #$7f,d0
        cmp.b   #$1d,d0                     ; Control (no Ace key): track it
        bne.s   .alt
        tst.b   d1
        smi     d0
        not.b   d0
        move.b  d0,ctrl_down
        bra     .loop
.alt:   cmp.b   #$38,d0                     ; Alt (also the Ace's Symbol Shift)
        bne.s   .q
        tst.b   d1
        smi     d2
        not.b   d2
        move.b  d2,alt_down
        bra.s   .hon
.q:     cmp.b   #$10,d0                     ; Control+Q: quit
        bne.s   .hon
        tst.b   d1
        bmi.s   .qup
        tst.b   ctrl_down
        beq.s   .hon
        st      q_down
        st      quit_flag
        bra     .loop
.qup:   clr.b   q_down
.hon:   tst.b   help_on                     ; keyboard picture shown:
        beq.s   .hlp                        ; swallow keys, any key closes it
        tst.b   d1
        bmi     .loop
        st      help_close
        bra     .loop
.hlp:   cmp.b   #$62,d1                     ; Help make: show the keyboard
        bne.s   .u
        st      help_req
        bra     .loop
.u:     cmp.b   #$61,d1                     ; Undo make: settings dialog
        bne.s   .o
        st      dlg_req
        bra     .loop
.o:     cmp.b   #$14,d1                     ; Alt+T make: screenshot
        bne.s   .o2
        tst.b   alt_down
        beq.s   .o2
        st      shot_req
        bra     .loop
.o2:    cmp.b   #$18,d1                     ; Control+O make: tape selector
        bne.s   .map
        tst.b   ctrl_down
        beq.s   .map
        st      open_flag
        bra     .loop
.map:   moveq   #0,d2
        move.b  d1,d2
        and.w   #$7f,d2
        lsl.w   #2,d2
        lea     keymap,a0
        adda.w  d2,a0
        lea     kbrows,a1
        moveq   #1,d3                       ; two key/mask pairs per entry
.pair:  moveq   #0,d0
        move.b  (a0)+,d0
        move.b  (a0)+,d2
        cmp.b   #8,d0
        bcc.s   .skip
        tst.b   d1                          ; bit 7 = break code
        bmi.s   .brk
        not.b   d2
        and.b   d2,(a1,d0.w)                ; key down: clear the bit
        bra.s   .skip
.brk:   or.b    d2,(a1,d0.w)                ; key up: set the bit
.skip:  dbra    d3,.pair
        bsr.s   keys_merge
        bra     .loop
.done:  bclr    #6,$fffffa11.w              ; end of interrupt (MFP ISRB bit 6)
        movem.l (sp)+,d0-d3/a0-a2
        rte

; The Ace sees keyrows = keyboard (kbrows) AND joystick (joyrows), so the
; stick and the keys do not release each other's keys.
keys_merge:
        move.l  kbrows,d0
        and.l   joyrows,d0
        move.l  d0,keyrows
        move.l  kbrows+4,d0
        and.l   joyrows+4,d0
        move.l  d0,keyrows+4
        rts

; joystick state changed (either port): the keys of joy_map for up, down,
; left, right, fire (ST scancodes, pressed through keymap like real keys)
joy_update:
        moveq   #-1,d0
        move.l  d0,joyrows
        move.l  d0,joyrows+4
        move.b  joy_port,d3
        or.b    joy_port+1,d3
        lea     joy_map,a1
        lea     joy_bits,a0
        moveq   #4,d2
.dir:   move.b  (a0)+,d0
        btst    d0,d3
        beq.s   .next
        moveq   #0,d1
        move.b  (a1),d1
        lsl.w   #2,d1
        movem.l d2/a0,-(sp)
        lea     keymap,a0
        adda.w  d1,a0
        moveq   #1,d1
.pair:  moveq   #0,d0
        move.b  (a0)+,d0
        move.b  (a0)+,d2
        cmp.b   #8,d0
        bcc.s   .np
        not.b   d2
        lea     joyrows,a2
        and.b   d2,(a2,d0.w)
.np:    dbra    d1,.pair
        movem.l (sp)+,d2/a0
.next:  addq.l  #1,a1
        dbra    d2,.dir
        bra     keys_merge

; all Ace keys up (keyboard and joystick)
keys_up:
        moveq   #-1,d0
        lea     keyrows,a0
        moveq   #5,d1
.cl:    move.l  d0,(a0)+
        dbra    d1,.cl
        clr.w   joy_port
        clr.b   joy_hdr
        rts

joy_bits:
        dc.b    0,1,2,3,7                   ; IKBD: up, down, left, right, fire
        even

; ---------------------------------------------------------------------------
        include "z80core.s"
        include "native.s"
        include "video.s"
        include "tape.s"
        include "gem.s"
        include "dialog.s"

skiptab:
        dc.b    7,5,2,2,2,2,6,2,1,1         ; IKBD headers $f6..$ff
        even

; ---------------------------------------------------------------------------
        section data,data

romname:  dc.b  "ACE.ROM",0
argtest:  dc.b  "SNAP.ACE",0
joy_map:  dc.b  $08,$07,$06,$09,$0b         ; keys 7 6 5 8 0 (up down left
          even                              ; right fire), ACE.INF can change
tapename: dc.b  "TAPE.ACE",0                ; path of the tape file
          dcb.b 160,0
shot_name: dc.b "ACE_0001.DOO",0
tape_mask: dc.b "*.*",0
tape_title: dc.b "Tape file",0
snap_mask: dc.b "*.ACE",0
snap_title: dc.b "Load snapshot",0
          even
aes_pb:   dc.l  aes_control,aes_global,aes_intin,aes_intout,aes_addrin,aes_addrout
msg_rez:  dc.b  "ACE-ST needs ST high or medium res.",13,10,0
msg_rom:  dc.b  "Cannot read ACE.ROM (8192 bytes).",13,10,0
badmsg:   dc.b  "Unimplemented Z80 opcode, PC="
badpc:    dc.b  "0000",13,10,0
hexchars: dc.b  "0123456789ABCDEF"
tracename: dc.b "TRACE.BIN",0
tracename2: dc.b "TRACEINT.BIN",0
tracename3: dc.b "TRACEMEM.BIN",0
tracename4: dc.b "TRACEIN.BIN",0
          even
kbpic:    incbin "kbpic.bin"                ; tools/kbpic.py, from EightyOne
          even
logopic:  incbin "logo.bin"                 ; assets/logo.pbm (tools/logo.sh)
          even
kbmed:    incbin "kbmed.bin"                ; ST medium versions (tools/medpic.py)
logomed:  incbin "logomed.bin"
pals:     dc.w  $000,$000,$777,$000         ; pal_ace
          dc.w  $777,$555,$333,$000         ; pal_pic
msg_mem:  dc.b  "Not enough memory for the trace buffer.",13,10,0
          even

; ---------------------------------------------------------------------------
        section bss,bss

        even
mem:         ds.b 65536+64
state:       ds.b ST_SIZE+12
        even
shadow:      ds.b 768
expand:      ds.b 512
        even
keyrows:     ds.b 8                         ; $ff = key up, set at start
kbrows:      ds.b 8                         ; the keyboard's part
joyrows:     ds.b 8                         ; the joystick's part
joy_port:    ds.b 2                         ; IKBD joystick state, ports 0/1
joy_hdr:     ds.b 1                         ; $FE/$FF: next byte is a joystick
        even
mystack:     ds.b 2048
mystack_top:
scr_ptr:     ds.l 1
old_ssp:     ds.l 1
old_timerc:  ds.l 1
old_ikbd:    ds.l 1
tape_fh:     ds.w 1
tape_tmp:    ds.b 4
tape_eof:    ds.b 1
tape_hdr_done: ds.b 1
tc_div:      ds.b 1
svc_tick:    ds.b 1
quit_flag:   ds.b 1
open_flag:   ds.b 1
help_req:    ds.b 1
any_key:     ds.b 1
help_on:     ds.b 1
help_close:  ds.b 1
ctrl_down:   ds.b 1
q_down:      ds.b 1
alt_down:    ds.b 1
shot_req:    ds.b 1
aes_init:    ds.b 1
medium:      ds.b 1                         ; $ff: ST medium
        even
ram_last:    ds.w 1                         ; last RAM address (see a3)
        even
old_pal:     ds.w 4
        even
aes_control: ds.w 6
aes_global:  ds.w 16
aes_intin:   ds.w 16
aes_intout:  ds.w 8
aes_addrin:  ds.l 2
aes_addrout: ds.l 2
fs_path:     ds.b 160                       ; file selector path + mask
fs_file:     ds.b 16                        ; and file name
fs_full:     ds.b 176                       ; path + name picked
snap_buf:    ds.l 1                         ; unpacked snapshot (Malloc)
snap_len:    ds.l 1                         ; bytes in the file (from 2000)
RDBUF equ 2048
rd_buf:      ds.b RDBUF
arg_name:    ds.b 128                       ; command line file
rsc_tree:    ds.l 1                         ; settings dialog (ACE.RSC)
dlg_x:       ds.w 4                         ; its rectangle
dlg_result:  ds.w 1
msgbuf:      ds.w 8
tokbuf:      ds.b 16                        ; ACE.INF word
dlg_req:     ds.b 1                         ; Undo pressed
dlg_ram:     ds.b 1                         ; RAM 0-3 (3K .. 51K) in the dialog
dlg_ram0:    ds.b 1                         ; and when it was opened
dlg_joy:     ds.b 5                         ; joystick scancodes in the dialog
        even
ikbd_skip:   ds.b 1
        even
icount:      ds.l 1                         ; ICOUNT build: instructions
iframes:     ds.l 1                         ; and 50 Hz ticks
trace_intf:  ds.b 1
trace_nat:   ds.b 1
        even
trace_buf:   ds.l 1
trace_ptr:   ds.l 1
trace_end:   ds.l 1
        ifd     TRACE
trace_cnt:   ds.l 1
trace_evp:   ds.l 1
TRACEEVB equ 24*24000
trace_ev:    ds.b TRACEEVB
trace_inp:   ds.l 1
trace_in:    ds.b 262144
        endif
        even
shot_buf:    ds.b 32000                     ; screenshot (640x400 mono)
        even
natab:       ds.l 8192                      ; native Forth words by ROM address
