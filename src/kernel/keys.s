; ---------------------------------------------------------------------------
; Ace keyboard matrix (kernel): ST scancodes and IKBD joystick state to the
; 8 Ace key rows the core reads (keyrows, bit clear = key down).
; ---------------------------------------------------------------------------

; ST key make/break: d1.w = scancode, bit 7 set for break.  Uses d0-d3/a0-a1.
key_event:
        moveq   #0,d2
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
