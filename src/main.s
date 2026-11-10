; ---------------------------------------------------------------------------
; ACE-ST: Jupiter Ace emulator for the Atari ST
; Program entry, system setup, interrupt handlers, data.
;
; Build:  make   (vasm, Motorola syntax, -Ftos)
; Needs:  ACE.ROM (8192 bytes, included, see ROM.md) in the current
;         directory, ST high (mono).
; Keys:   Control+Q quits, Control+O picks the tape file (GEM file selector),
;         Help shows the Ace keyboard (Help again goes back).
; GPL v2 or later.
; ---------------------------------------------------------------------------

        include "macros.s"

        section text,code

start:
        movea.l 4(sp),a0                    ; basepage
        lea     mystack_top,sp
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
        pea     msg_rez
        bra     fail
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

        ; RAM: all 48K present, filled with $FF like xAce
        lea     mem+8192,a0
        move.w  #(57344/4)-1,d0
.fill:  move.l  #-1,(a0)+
        dbra    d0,.fill

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

        lea     keyrows,a0
        moveq   #-1,d0
        move.l  d0,(a0)+
        move.l  d0,(a0)
        move.w  #-1,tape_fh
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
        move.b  #$12,d0                     ; IKBD: disable mouse
        bsr     ikbd_send
        move.b  #$1a,d0                     ; IKBD: disable joysticks
        bsr     ikbd_send

        ; startup screen: the Jupiter Ace logo for 2 s (a key skips it)
        move.w  #(400-LOGO_H)/2,d0
        jsr     draw_logo
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
        lea     keyrows,a0                  ; forget keys pressed meanwhile
        moveq   #-1,d0
        move.l  d0,(a0)+
        move.l  d0,(a0)
        clr.b   help_req
        clr.b   open_flag
        movea.l scr_ptr,a0                  ; black screen for the Ace
        move.w  #(32000/4)-1,d0
.clr:   move.l  #-1,(a0)+
        dbra    d0,.clr

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

        ; Z80 reset
        lea     mem,a5
        lea     state,a6
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
.rel:   tst.b   ctrl_down                   ; wait until Control and Q are up,
        bne.s   .rel                        ; so no key reaches the desktop
        tst.b   q_down
        bne.s   .rel
        move.w  #$2700,sr
        move.l  old_timerc,$114.w
        move.l  old_ikbd,$118.w
        move.w  #$2000,sr
        move.b  #$08,d0                     ; IKBD: mouse relative
        bsr     ikbd_send
        move.b  #$14,d0                     ; IKBD: joystick events
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
        dc.w    $a009                       ; Line-A show mouse
        clr.w   -(sp)                       ; Cursconf(1 = show, rate 0)
        move.w  #1,-(sp)
        move.w  #21,-(sp)
        trap    #14
        addq.l  #6,sp
leave:
        move.l  old_ssp,-(sp)
        move.w  #$20,-(sp)                  ; Super (back to user mode)
        trap    #1
        clr.w   -(sp)                       ; Pterm0
        trap    #1

; called from do_int every 20 ms with the Z80 registers live: save everything
host_service:
        movem.l d0-d7/a0-a6,-(sp)
        tst.b   help_req
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
.no:
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

; Help: show the Jupiter Ace logo and EightyOne's keyboard picture
; (512x223, 1 bit) on a white screen; the Ace stops until Help again
; (or Control+Q).
help_show:
        clr.b   help_req
        move.w  #HELP_Y,d0
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
        clr.b   help_close
        st      help_on
.wait:  tst.b   quit_flag
        bne.s   .done
        tst.b   help_close
        beq.s   .wait
.done:  clr.b   help_on
        lea     keyrows,a0                  ; all Ace keys up
        moveq   #-1,d0
        move.l  d0,(a0)+
        move.l  d0,(a0)
        movea.l scr_ptr,a0                  ; black screen, full redraw
        move.w  #(32000/4)-1,d0
.blk:   move.l  #-1,(a0)+
        dbra    d0,.blk
        st      state+ST_REDRAW
        rts

KBPIC_H equ 223
HELP_Y  equ (400-LOGO_H-16-KBPIC_H)/2       ; logo, 16 lines gap, keyboard
KBPIC_Y equ HELP_Y+LOGO_H+16

; White screen with the Jupiter Ace logo (448x103, 1 bit) centred
; horizontally, top line in d0.w.
draw_logo:
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

LOGO_W  equ 56                              ; bytes per line
LOGO_H  equ 103

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
        movem.l d0-d3/a0-a1,-(sp)
.loop:  move.b  $fffffc00.w,d0
        btst    #0,d0                       ; receive data ready?
        beq     .done
        moveq   #0,d1
        move.b  $fffffc02.w,d1
        tst.b   ikbd_skip
        beq.s   .nopkt
        subq.b  #1,ikbd_skip                ; payload of a mouse/joystick packet
        bra.s   .loop
.nopkt: cmp.b   #$f6,d1
        bcs.s   .key
        sub.b   #$f6,d1                     ; packet header: bytes still to come
        lea     skiptab,a0
        move.b  (a0,d1.w),ikbd_skip
        bra.s   .loop
.key:   tst.b   d1                          ; any make code (startup screen)
        bmi.s   .kb
        st      any_key
.kb:    move.b  d1,d0
        and.b   #$7f,d0
        cmp.b   #$1d,d0                     ; Control (no Ace key): track it
        bne.s   .q
        tst.b   d1
        smi     d0
        not.b   d0
        move.b  d0,ctrl_down
        bra     .loop
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
        beq.s   .hlp                        ; swallow keys, Help closes it
        cmp.b   #$62,d1
        bne     .loop
        st      help_close
        bra     .loop
.hlp:   cmp.b   #$62,d1                     ; Help make: show the keyboard
        bne.s   .o
        st      help_req
        bra     .loop
.o:     cmp.b   #$18,d1                     ; Control+O make: tape selector
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
        lea     keyrows,a1
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
        bra     .loop
.done:  bclr    #6,$fffffa11.w              ; end of interrupt (MFP ISRB bit 6)
        movem.l (sp)+,d0-d3/a0-a1
        rte

; ---------------------------------------------------------------------------
        include "z80core.s"
        include "native.s"
        include "video.s"
        include "tape.s"

skiptab:
        dc.b    7,5,2,2,2,2,6,2,1,1         ; IKBD headers $f6..$ff
        even

; ---------------------------------------------------------------------------
        section data,data

romname:  dc.b  "ACE.ROM",0
tapename: dc.b  "TAPE.ACE",0                ; path of the tape file
          dcb.b 160,0
fs_mask:  dc.b  $5c,"*.*",0
          even
aes_pb:   dc.l  aes_control,aes_global,aes_intin,aes_intout,aes_addrin,aes_addrout
msg_rez:  dc.b  "ACE-ST needs ST high resolution (mono).",13,10,0
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
aes_init:    ds.b 1
        even
aes_control: ds.w 6
aes_global:  ds.w 16
aes_intin:   ds.w 4
aes_intout:  ds.w 4
aes_addrin:  ds.l 2
aes_addrout: ds.l 2
fs_path:     ds.b 160                       ; file selector path + mask
fs_file:     ds.b 16                        ; and file name
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
natab:       ds.l 8192                      ; native Forth words by ROM address
