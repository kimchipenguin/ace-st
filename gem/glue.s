; ---------------------------------------------------------------------------
; ACEGEM: the ACE-ST kernel for the GEM front end, with the glue to C.
; Assembled twice by gem/Makefile (vasm -Faout -DGEMAPP): the first time
; without FLAGTAB for the listing that tools/flagtab.py turns into
; build/flagtab.i (the offsets of all GETF sites), then with it.  The table
; is in the data section, so the code is the same both times.
; GPL v2 or later.
; ---------------------------------------------------------------------------
        include "macros.s"

        section text

        xdef    _kernel_start,_kernel_init,_kernel_run,_kernel_keys_up
        xdef    _kernel_key,_kernel_joy,_kernel_flags,_kernel_nflags
        xdef    _gk_timer_on,_gk_timer_off,_gk_ikbd_on,_gk_ikbd_off
        xdef    _gk_down,_gk_ring,_gk_rin,_gk_hooked,_gk_flush030,_gk_flush040
        xdef    _ace_mem,_ace_state,_ace_ram_last,_ace_ticks200,_ace_shadow
        xdef    _ace_tapename,_ace_snap_buf,_ace_snap_read
        xdef    _ace_joy_map,_ace_keyname,_kernel_tape_close
        xdef    _ace_keyrows,_kernel_matrix,_gk_refresh,_gk_expand
        xdef    _ace_slot_base,_ace_slots,_ace_budget,_gk_throttle,_ace_natab
        xdef    _ace_cb_table,_ace_dd_table,_ace_ed_table,_ace_fd_table
        xdef    _ace_ddcb_table
        xref    _gem_frame,_gem_sound,_gem_throttle

_kernel_start:
        include "kernel.i"

; ---------------------------------------------------------------------------
; C interface (gem/kernel.h).  C keeps d2-d7/a2-a6.
; ---------------------------------------------------------------------------

; void kernel_init(void)
_kernel_init:
        move.l  #slot_base+$8000,_ace_slots
        jmp     kernel_init

; void kernel_keys_up(void)
_kernel_keys_up:
        movem.l d2-d3/a2,-(sp)
        jsr     keys_up
        movem.l (sp)+,d2-d3/a2
        rts

; void kernel_key(int scancode): bit 7 = break
_kernel_key:
        movem.l d2-d3,-(sp)
        move.l  12(sp),d1
        jsr     key_event
        movem.l (sp)+,d2-d3
        rts

; void kernel_joy(int port1): joystick 1 bits (IKBD: up down left right ..
; fire = bit 7)
_kernel_joy:
        movem.l d2-d3/a2,-(sp)
        move.l  16(sp),d0
        move.b  d0,joy_port+1
        jsr     joy_update
        movem.l (sp)+,d2-d3/a2
        rts

; int kernel_run(int snap): runs the Ace (from snap_buf when snap != 0)
; until gem_frame() says quit; returns 0 (quit) or -1 (host_exit: bad
; opcode).  The Ace's stack is the C stack below the saved registers.
_kernel_run:
        move.l  4(sp),d0
        movem.l d2-d7/a2-a6,-(sp)
        move.l  sp,run_sp
        tst.l   d0
        beq.s   .reset
        jmp     snap_start
.reset: jmp     z80_reset

host_exit:
        moveq   #-1,d0
        bra.s   kr_leave

; every 20 ms from do_int: gem_frame() returns 0 go on, 1 reset, 2 start
; snap_buf, 3 quit
host_service:
        movem.l d0-d7/a0-a6,-(sp)
        jsr     _gem_frame
        tst.l   d0
        bne.s   .act
        move.l  _ace_slots,48(sp)           ; a4: the speed limit on or off
        movem.l (sp)+,d0-d7/a0-a6
        rts
.act:   subq.l  #1,d0
        bne.s   .nrs
        jmp     z80_reset
.nrs:   subq.l  #1,d0
        bne.s   .quit
        jmp     snap_start
.quit:  moveq   #0,d0
kr_leave:
        movea.l run_sp,sp
        movem.l (sp)+,d2-d7/a2-a6
        rts

; Speed limit (gem/speed.c): the stubs that count the Ace's T-states
; call this when _ace_budget is used up.  gem_throttle() waits for the next
; 50 Hz tick.  Keeps all registers.
_gk_throttle:
        movem.l d0-d7/a0-a6,-(sp)
        jsr     _gem_throttle
        movem.l (sp)+,d0-d7/a0-a6
        rts

; BEEP's tone (host.i): gem_sound(period), 0 = off.  Keep all registers
; but d0.
host_snd_off:
        moveq   #0,d0
host_snd_on:
        movem.l d1-d7/a0-a6,-(sp)
        and.l   #$ffff,d0
        move.l  d0,-(sp)
        jsr     _gem_sound
        addq.l  #4,sp
        movem.l (sp)+,d1-d7/a0-a6
        rts

; void kernel_tape_close(void): before a new tape name (between frames, so
; no tape operation is running)
_kernel_tape_close:
        movem.l d2-d7/a2-a6,-(sp)
        jsr     tape_close
        movem.l (sp)+,d2-d7/a2-a6
        rts

; void kernel_matrix(int row, int mask, int down): one Ace key (row 0-7 of
; the matrix, its bit) pressed or released, as the keyboard window clicks it
_kernel_matrix:
        move.l  4(sp),d0
        move.l  8(sp),d1
        lea     kbrows,a0
        tst.l   12(sp)
        beq.s   .up
        not.b   d1
        and.b   d1,(a0,d0.w)
        bra     keys_merge
.up:    or.b    d1,(a0,d0.w)
        bra     keys_merge

; void gk_expand(void): once, before gk_refresh
_gk_expand:
        movem.l d2-d3,-(sp)
        jsr     build_expand
        movem.l (sp)+,d2-d3
        rts

; void gk_refresh(void *screen, int medium): full screen on the ST
; shifter: the changed cells straight into ST high (medium = 0) or ST
; medium screen memory, as ACE.PRG draws them (render.s); the screen is
; black ($FF) around them
_gk_refresh:
        movem.l d2-d7/a2-a6,-(sp)
        move.l  48(sp),scr_ptr
        lea     mem,a5
        lea     state,a6
        tst.l   52(sp)
        bne.s   .med
        bsr.s   gr_high
        bra.s   .out
.med:   bsr     gr_med
.out:   movem.l (sp)+,d2-d7/a2-a6
        rts
gr_high:
        REFRESH 0
gr_med:
        REFRESH 1

; int ace_snap_read(const char *name): 0 fine, -1 cannot read, -2 not a
; snapshot, -3 no memory
_ace_snap_read:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        jsr     snap_read
        movem.l (sp)+,d2-d7/a2-a6
        rts

; long gk_flush030(void), gk_flush040(void): caches clean after the GETF
; patch (Supexec; movec and cpusha as words, the file is -m68000)
_gk_flush030:
        dc.w    $4e7a,$0002                 ; movec cacr,d0
        or.w    #$0808,d0                   ; clear data + instruction cache
        dc.w    $4e7b,$0002                 ; movec d0,cacr
        moveq   #0,d0
        rts
_gk_flush040:
        dc.w    $f4f8                       ; cpusha bc
        moveq   #0,d0
        rts

; ---------------------------------------------------------------------------
; Timer C (200 Hz, XBRA): ticks200 for BEEP, ST_INT every 4th tick (50 Hz)
; ---------------------------------------------------------------------------
        dc.b    "XBRA","AceG"
old_timerc:
        dc.l    0
gk_timerc:
        addq.l  #1,ticks200
        subq.b  #1,tc_div
        bne.s   .chain
        move.b  #4,tc_div
        st      state+ST_INT
.chain: move.l  old_timerc,-(sp)
        rts

; long gk_timer_on(void), gk_timer_off(void): for Supexec
_gk_timer_on:
        move.b  #4,tc_div
        move.l  $114.w,old_timerc
        move.l  #gk_timerc,$114.w
        moveq   #0,d0
        rts

_gk_timer_off:
        lea     $114.w,a1
        lea     gk_timerc,a2

; Take the XBRA handler a2 out of the chain that starts at the vector (a1),
; also when others came after it.  d0 = 0, or -1 when not found (a handler
; without XBRA is in front of it: then it stays).
xb_unlink:
.walk:  movea.l (a1),a0
        cmpa.l  a2,a0
        beq.s   .found
        cmp.l   #'XBRA',-12(a0)
        bne.s   .fail
        lea     -4(a0),a1
        bra.s   .walk
.found: move.l  -4(a2),(a1)
        moveq   #0,d0
        rts
.fail:  moveq   #-1,d0
        rts

; ---------------------------------------------------------------------------
; IKBD (Kbdvbase()->ikbdsys, XBRA) while the Ace window is on top: key
; make/break codes go to the Ace's key matrix, and into gk_down[] for the
; front end; keys with Control held go to gk_ring[] instead (the shortcuts,
; menus in a later version).  Mouse packets go on to TOS's mousevec, so
; the AES keeps its mouse; joystick 1 packets go to the Ace.
; ---------------------------------------------------------------------------
        dc.b    "XBRA","AceG"
old_ikbd:
        dc.l    0
gk_ikbdsys:
        movem.l d0-d3/a0-a2,-(sp)
.loop:  move.b  $fffffc00.w,d0
        btst    #0,d0
        beq.s   .done
        moveq   #0,d1
        move.b  $fffffc02.w,d1
        bsr.s   gk_byte
        bra.s   .loop
.done:  movem.l (sp)+,d0-d3/a0-a2
        rts

; d1.w = one byte from the keyboard processor
gk_byte:
        move.w  pk_need,d0
        beq.s   .nopk
        lea     pk_buf,a0
        move.w  pk_have,d2
        move.b  d1,(a0,d2.w)
        addq.w  #1,d2
        move.w  d2,pk_have
        cmp.w   d0,d2
        bcs.s   .ret
        clr.w   pk_need
        move.b  (a0),d0
        cmp.b   #$f8,d0
        bcs.s   .ret                        ; status, absolute mouse
        cmp.b   #$fc,d0
        bcs.s   .mouse
        cmp.b   #$ff,d0
        bne.s   .ret                        ; clock, joystick report, port 0
        tst.b   _gk_hooked
        bpl.s   .ret                        ; going: keys only up
        move.b  1(a0),joy_port+1
        jmp     joy_update
.mouse: movem.l d4-d7/a3-a6,-(sp)
        movea.l kbdvecs,a1
        movea.l 16(a1),a1                   ; mousevec
        move.l  a0,-(sp)
        jsr     (a1)
        addq.l  #4,sp
        movem.l (sp)+,d4-d7/a3-a6
.ret:   rts
.nopk:  cmp.w   #$f6,d1
        bcs.s   .key
        lea     pk_len-$f6,a0
        move.b  (a0,d1.w),d0
        move.w  d0,pk_need
        move.w  #1,pk_have
        move.b  d1,pk_buf
        rts
.key:   move.w  d1,d0
        and.w   #$7f,d0
        lea     _gk_down,a0
        tst.b   d1
        bmi.s   .brk
        st      (a0,d0.w)
        cmp.w   #$1d,d0                     ; Control itself
        beq.s   .ace
        cmp.w   #$61,d0                     ; Undo: the front end's too
        beq.s   .ring
        tst.b   $1d(a0)
        beq.s   .ace
.ring:  moveq   #0,d2                       ; Control + key: the front end's
        move.b  _gk_rin,d2
        lea     _gk_ring,a1
        move.b  d0,(a1,d2.w)
        addq.b  #1,d2
        and.b   #15,d2
        move.b  d2,_gk_rin
        rts
.ace:   tst.b   _gk_hooked
        bpl.s   .ret                        ; going: no new keys
        jmp     key_event
.brk:   clr.b   (a0,d0.w)
        jmp     key_event

; long gk_ikbd_on(void), gk_ikbd_off(void): for Supexec
_gk_ikbd_on:
        move.w  #34,-(sp)                   ; Kbdvbase (traps are fine in
        trap    #14                         ; supervisor mode)
        addq.l  #2,sp
        move.l  d0,kbdvecs
        movea.l d0,a0
        clr.w   pk_need
        move.l  32(a0),old_ikbd
        move.l  #gk_ikbdsys,32(a0)
        moveq   #0,d0
        rts

_gk_ikbd_off:
        movea.l kbdvecs,a1
        lea     32(a1),a1
        lea     gk_ikbdsys,a2
        bra     xb_unlink

; ---------------------------------------------------------------------------
        section data,data

pk_len:   dc.b  8,6,3,3,3,3,7,3,2,2         ; bytes of the packets $F6-$FF
          even
_kernel_flags:
        ifd     FLAGTAB
        include "flagtab.i"
        if      flagcnt<>gfcnt
        fail    "flagtab.i is out of date"
        endif
        endif
_kernel_nflags:
        ifd     FLAGTAB
        dc.l    flagcnt
        else
        dc.l    0
        endif

_ace_mem        equ     mem
_ace_state      equ     state
_ace_ram_last   equ     ram_last
_ace_ticks200   equ     ticks200
_ace_shadow     equ     shadow
_ace_tapename   equ     tapename
_ace_snap_buf   equ     snap_buf
_ace_joy_map    equ     joy_map
_ace_keyname    equ     keyname
_ace_keyrows    equ     keyrows
_ace_slot_base  equ     slot_base
_ace_natab      equ     natab
_ace_cb_table   equ     cb_table
_ace_dd_table   equ     dd_table
_ace_ed_table   equ     ed_table
_ace_fd_table   equ     fd_table
_ace_ddcb_table equ     ddcb_table

        include "kdata.s"

        section bss,bss
        even
kbdvecs:     ds.l 1
scr_ptr:     ds.l 1                         ; gk_refresh's screen
pk_need:     ds.w 1
pk_have:     ds.w 1
pk_buf:      ds.b 8
_gk_down:    ds.b 128                       ; ST keys held (IKBD hook)
_gk_ring:    ds.b 16                        ; Control + key make codes
_gk_rin:     ds.b 1                         ; next free slot in _gk_ring
_gk_hooked:  ds.b 1                         ; $ff hooked, 1 going (keys up only)
tc_div:      ds.b 1
        even
_ace_slots:  ds.l 1                         ; a4: slot_mid, or the stubs'
_ace_budget: ds.l 1                         ; T-states left in this frame
