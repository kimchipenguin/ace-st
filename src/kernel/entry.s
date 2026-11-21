; ---------------------------------------------------------------------------
; Kernel entry points.  The front end sets run_sp (the stack the Ace runs
; on, restarted at every reset or snapshot) and calls or jumps to these.
; ---------------------------------------------------------------------------

; Once, with the ROM in mem: the ROM patches (ED xx traps for the native
; routines), natab, all keys up, no tape file open.  Keeps d2-d7/a2-a6.
kernel_init:
        movem.l d2-d7/a2-a6,-(sp)
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
        ifnd    NONATIVE
        jsr     native_init
        endif
        movem.l (sp)+,d2-d7/a2-a6
        rts

; Z80 reset, as at power on: everything above the ROM reads $FF (like xAce;
; also where there is no RAM), the machine state cleared, PC = 0, a3 = last
; RAM address from ram_last.  Also the settings dialog's Reset (and RAM
; size change): the stack starts again at run_sp (set by the front end).
z80_reset:
        movea.l run_sp,sp
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
        ifd     GEMAPP
        movea.l _ace_slots,a4               ; slot_mid or the speed stubs
        else
        lea     slot_base+$8000,a4          ; slot_mid
        endif
        movea.l a5,a0                       ; PC = 0
        movea.l a5,a1
        adda.l  #65536,a1                   ; SP = 0
        moveq   #0,d3
        moveq   #0,d4
        moveq   #0,d5
        moveq   #0,d6
        moveq   #0,d7
        NEXT

