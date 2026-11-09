; ---------------------------------------------------------------------------
; Z80 core support routines (see macros.s for register allocation)
; GPL v2 or later.
; ---------------------------------------------------------------------------

; Store to 0x0000-0x3FFF.  d1.l = address, d2.b = value.  Clobbers d0.
;   0000-1FFF  ROM, write ignored
;   2000-27FF  video RAM, 1K mirrored (xor $400); marks the screen dirty
;   2800-2FFF  character RAM, 1K mirrored (xor $400); triggers full redraw
;   3000-3FFF  1K user RAM mirrored four times
store_low:
        cmp.w   #$2000,d1
        bcs.s   .rom
        move.b  d2,(a5,d1.l)
        cmp.w   #$3000,d1
        bcc.s   .ram1k
        cmp.w   #$2800,d1
        bcs.s   .vid
        st      ST_REDRAW(a6)
        bra.s   .mir
.vid:   st      ST_VDIRTY(a6)
.mir:
        moveq   #0,d0
        move.w  d1,d0
        eori.w  #$0400,d0
        move.b  d2,(a5,d0.l)
.rom:
        rts
.ram1k:
        moveq   #0,d0
        move.w  d1,d0
        and.w   #$03ff,d0
        add.w   #$3000,d0
        move.b  d2,(a5,d0.l)
        add.w   #$0400,d0
        move.b  d2,(a5,d0.l)
        add.w   #$0400,d0
        move.b  d2,(a5,d0.l)
        add.w   #$0400,d0
        move.b  d2,(a5,d0.l)
        rts

; Z80 F byte (d0) -> flag image (d3).  H and N are not represented.
z80_to_f:
        moveq   #0,d3
        btst    #7,d0
        beq.s   .a
        or.b    #$08,d3
.a:     btst    #6,d0
        beq.s   .b
        or.b    #$04,d3
.b:     btst    #2,d0
        beq.s   .c
        or.b    #$02,d3
.c:     btst    #0,d0
        beq.s   .d
        or.b    #$11,d3
.d:     rts

; flag image (d3) -> Z80 F byte (d0)
f_to_z80:
        moveq   #0,d0
        btst    #3,d3
        beq.s   .a
        or.b    #$80,d0
.a:     btst    #2,d3
        beq.s   .b
        or.b    #$40,d0
.b:     btst    #1,d3
        beq.s   .c
        or.b    #$04,d0
.c:     btst    #0,d3
        beq.s   .d
        or.b    #$01,d0
.d:     rts

; Port input.  d0.b = port low byte, d1 = port high byte.  Returns d2.b.
; Only the keyboard (port 0xFE) is decoded; the high byte selects half rows
; (active low) and the selected rows are ANDed together.
in_port:
        moveq   #-1,d2
        cmp.b   #$fe,d0
        bne.s   .done
        lea     keyrows,a2
        moveq   #0,d0
.row:   btst    d0,d1
        bne.s   .skip
        and.b   (a2,d0.w),d2
.skip:  addq.b  #1,d0
        cmp.b   #8,d0
        bne.s   .row
.done:
        ifd     TRACE
        movea.l trace_inp,a2                ; log every port read
        cmpa.l  #trace_in+262144,a2
        bcc.s   .full
        move.b  d2,(a2)+
        move.l  a2,trace_inp
.full:
        endif
        rts

; Native version of the ROM keyboard scan at 0x0336 (patched to ED FE C9,
; the trap runs this, then the RET at 0x0338 returns).  Leaves every Z80
; register and the S Z PV C flags exactly as the ROM code does:
;   0336 LD BC,FEFE / IN D,(C) / work out the shift offset into L
;   per row: CPL / AND 1F; one key -> E = index, two keys -> E = FF;
;   DEC L, RLC B, next row (IN A,(C)) until B rotates back to FE
;   036D A = E+1: 0 -> RET Z, else HL = 0376+DE, A = (HL)
; Port reads are logged like in_port's in trace builds.
KLOG    macro
        ifd     TRACE
        jsr     trace_klog
        endif
        endm

kb_scan:
        lea     keyrows,a2
        moveq   #0,d1                       ; row 0 (B = FE)
        move.b  (a2),d2                     ; IN D,(C)
        KLOG
        moveq   #0,d0                       ; SRL D / SBC A,A / AND D8
        btst    #0,d2
        beq.s   .s1
        move.b  #$d8,d0
.s1:    btst    #1,d2                       ; SRL D / JR C / LD A,28
        bne.s   .s2
        moveq   #$28,d0
.s2:    add.b   #$57,d0
        move.b  d0,d6                       ; LD L,A
        or.b    #3,d2                       ; LD A,E / OR 3
        st      d5                          ; LD E,FF
.loop:  not.b   d2                          ; CPL / AND 1F / LD D,A
        and.b   #$1f,d2
        move.b  d2,d3                       ; d3 = D while scanning
        beq.s   .next
        move.b  d6,d2                       ; LD A,L
        addq.b  #1,d5                       ; INC E
        bne.s   .two                        ; second key (carry 0)
.find:  subq.b  #8,d2                       ; SUB 8 / SRL D / JR NC
        lsr.b   #1,d3
        bcc.s   .find
        move.b  d2,d5                       ; LD E,A
        tst.b   d3
        bne.s   .many                       ; more keys in this row (carry 1)
.next:  subq.b  #1,d6                       ; DEC L
        addq.w  #1,d1                       ; RLC B
        cmp.w   #8,d1
        beq.s   .all
        move.b  (a2,d1.w),d2                ; IN A,(C)
        KLOG
        bra.s   .loop
.all:   moveq   #0,d1                       ; B back at FE (= row 0), carry 0
        moveq   #0,d0
        bra.s   .end
.two:   moveq   #0,d0                       ; carry clear
        st      d5
        bra.s   .end
.many:  moveq   #1,d0                       ; carry set
        st      d5
.end:   ; BC: B = row select (FE once all rows are done), C = FE
        moveq   #-1,d2
        bclr    d1,d2
        lsl.w   #8,d2
        move.b  #$fe,d2
        move.w  d2,d4
        ; DE: D = d3, E = d5
        move.b  d3,d2
        lsl.w   #8,d2
        move.b  d5,d2
        move.w  d2,d5
        and.l   #$ffff,d5
        cmp.b   #$ff,d5
        bne.s   .key
        moveq   #0,d7                       ; INC A -> 0: Z set, carry kept
        moveq   #4,d3
        or.b    d0,d3
        rts
.key:   moveq   #0,d6                       ; HL = 0376 + DE (D is 0 here)
        move.b  d5,d6
        add.w   #$0376,d6
        move.b  (a5,d6.l),d7                ; LD A,(HL)
        moveq   #0,d3                       ; S Z PV C all clear
        rts

; Native version of the code every Forth primitive ends with (JP (IY),
; IY = 04C8), patched to ED FF at 0x04C8 (a0 = mem+04CA on entry):
;   04C8 data stack vs dictionary: ([3C37]+11) - [3C3B] must borrow
;   04D9 CALL 0F8C with BC=0: 1E+[3C3B] must not carry and must be < SP-2
;   04DF CALL 04E4: BREAK unless Shift (row FE bit 0) or Space (row 7F)
;        is up
;   04B9 NEXT: POP HL / fetch W at IP / PUSH IP+2 / DE = W+2, JP ((W))
; When a check fails it does LD BC,11 and goes on at 04CB, so the ROM code
; reports the error.  Registers, S Z PV C flags and the bytes the calls
; leave below SP end up as after the ROM code.
forth_next:
        move.b  $3c38(a5),-(sp)             ; d1.w = [3C37] (byte pushed on
        move.w  (sp)+,d1                    ; a7 lands in the high half)
        move.b  $3c37(a5),d1
        move.b  $3c3c(a5),-(sp)             ; d2.w = [3C3B]
        move.w  (sp)+,d2
        move.b  $3c3b(a5),d2
        cmp.w   #$fff5,d1                   ; ADD HL,11 carries: exact code
        bcc     .wrap
        ifd     FNTEST_WRAP                 ; test: always the exact code
        bra     .wrap
        endif
        add.w   #11,d1                      ; no carry: SBC borrows when
        cmp.w   d2,d1                       ; [3C37]+11 < [3C3B]
        bcc     .slow                       ; no borrow: error 2
.chk2:  add.w   #$1e,d2                     ; HL = 1E + [3C3B]
        bcs     .slow                       ; carry: error 1
        move.l  a1,d0                       ; SP inside the CALL
        sub.l   a5,d0
        subq.w  #2,d0
        sub.w   d0,d2                       ; SBC HL,SP
        bcc     .slow
        move    sr,d4                       ; S = N, PV = V
        and.w   #$0a,d4
        lea     keyrows,a2
        move.b  (a2),d2                     ; IN A,(FE) with A = FE
        btst    #0,d2
        bne.s   .nobrk
        btst    #0,7(a2)
        beq     .slow                       ; Shift + Space: BREAK
        KLOG
        move.b  7(a2),d2                    ; IN A,(FE) with A = 7F
        KLOG
        lsr.b   #1,d2                       ; RRA, carry in 0
        bra.s   .rra
.nobrk: KLOG
        lsr.b   #1,d2                       ; RRA, carry in 1 (from SBC)
        or.b    #$80,d2
.rra:   move.b  d2,d7
        or.w    #$11,d4                     ; C = 1 from RRA
        move.w  d4,d3
        move.w  a1,d0                       ; a5 is even: host parity =
        btst    #0,d0                       ; Z80 SP parity
        bne.s   .odd
        ifd     FNTEST_ODD                  ; test: always the byte code
        bra.s   .odd
        endif
        move.l  #$0000e204,-4(a1)           ; left by CALL 04E4 / PUSH BC
        moveq   #0,d1                       ; IP from the stack (a word,
        move.w  (a1),d1                     ; byte-swapped)
        rol.w   #8,d1
        moveq   #0,d6                       ; W = (IP)
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d6
        move.b  (a5,d1.l),d6
        addq.w  #2,d1                       ; IP+2 back on the stack
        rol.w   #8,d1
        move.w  d1,(a1)
.hl:    moveq   #0,d5                       ; HL = (W), DE = W+2
        move.w  d6,d5
        move.b  1(a5,d5.l),-(sp)
        move.w  (sp)+,d6
        move.b  (a5,d5.l),d6
        addq.w  #2,d5
        moveq   #0,d4                       ; BC = 0
        lea     (a5,d6.l),a0
        CHKINT
        NEXT
.odd:   move.b  #$04,-1(a1)                 ; odd SP: byte by byte
        move.b  #$e2,-2(a1)
        clr.b   -3(a1)
        clr.b   -4(a1)
        moveq   #0,d1
        move.b  1(a1),d1
        lsl.w   #8,d1
        move.b  (a1),d1
        RDW     d6                          ; W = (IP)
        addq.w  #2,d1
        move.b  d1,(a1)
        move.w  d1,d0
        lsr.w   #8,d0
        move.b  d0,1(a1)
        bra.s   .hl
.wrap:  moveq   #0,d0                       ; [3C37] >= FFF5: SBC HL,DE with
        move.w  d1,d0                       ; the ADD's carry, as the ROM
        add.l   #11,d0
        moveq   #0,d1
        move.w  d2,d1
        swap    d0                          ; d0.w = carry, high = HL
        moveq   #0,d4
        move.w  d0,d4
        clr.w   d0
        swap    d0
        sub.l   d1,d0
        sub.l   d4,d0
        bpl.s   .slow                       ; no borrow: error 2
        bra     .chk2
.slow:  moveq   #11,d4                      ; LD BC,11, on at 04CB
        addq.l  #1,a0
        NEXT

; The ROM's Forth data stack routines (stack pointer at 3C3B, growing
; upwards).  They change no flags and leave HL = the new pointer.
;   RST 10   push DE: (ptr) = E, (ptr+1) = D, ptr += 2
;   RST 18   pop DE:  ptr -= 2, D = (ptr+1), E = (ptr)
;   084E     pop BC (CALLed; patched to ED FB): ptr -= 2, B, C, RET
; The RST handlers also leave the return address below SP, as RST + RET do.
DSPTR   macro                               ; d1 = [3C3B]
        moveq   #0,d1
        move.b  $3c3c(a5),d1
        lsl.w   #8,d1
        move.b  $3c3b(a5),d1
        endm

DSSET   macro                               ; [3C3B] = HL (d6) and its three
        move.b  d6,$303b(a5)                ; 1K RAM mirrors; clobbers d0
        move.b  d6,$343b(a5)
        move.b  d6,$383b(a5)
        move.b  d6,$3c3b(a5)
        move.w  d6,d0
        lsr.w   #8,d0
        move.b  d0,$303c(a5)
        move.b  d0,$343c(a5)
        move.b  d0,$383c(a5)
        move.b  d0,$3c3c(a5)
        endm

RSTADR  macro                               ; return address below SP
        move.l  a0,d0
        sub.l   a5,d0
        move.b  d0,-2(a1)
        lsr.w   #8,d0
        move.b  d0,-1(a1)
        endm

ds_push:
        RSTADR
        DSPTR
        cmp.w   #$4000,d1
        bcs.s   .low
        cmp.w   #$ffff,d1                   ; D would land at 0000 (ROM)
        beq     .gen
        move.b  d5,(a5,d1.l)                ; plain RAM: LD (HL),E / D
        move.w  d5,d0
        lsr.w   #8,d0
        move.b  d0,1(a5,d1.l)
.set:   addq.w  #2,d1
        move.l  d1,d6
        DSSET
        CHKINT
        NEXT
.low:   cmp.w   #$3000,d1                   ; 1K RAM, both bytes in one copy:
        bcs     .gen                        ; write them and their mirrors
        move.w  d1,d0
        and.w   #$03ff,d0
        cmp.w   #$03ff,d0
        beq     .gen
        lea     (a5,d0.w),a2
        move.b  d5,$3000(a2)
        move.b  d5,$3400(a2)
        move.b  d5,$3800(a2)
        move.b  d5,$3c00(a2)
        move.w  d5,d0
        lsr.w   #8,d0
        move.b  d0,$3001(a2)
        move.b  d0,$3401(a2)
        move.b  d0,$3801(a2)
        move.b  d0,$3c01(a2)
        bra     .set
.gen:   move.b  d5,d2                       ; anything else: checked stores
        STORE
        addq.w  #1,d1
        move.w  d5,d2
        lsr.w   #8,d2
        STORE
        subq.w  #1,d1
        bra     .set

ds_pop:
        RSTADR
        DSPTR
        subq.w  #1,d1
        moveq   #0,d5
        move.b  (a5,d1.l),d5                ; D
        lsl.w   #8,d5
        subq.w  #1,d1
        move.b  (a5,d1.l),d5                ; E
        move.l  d1,d6
        DSSET
        CHKINT
        NEXT

ds_popbc:
        DSPTR
        subq.w  #1,d1
        moveq   #0,d4
        move.b  (a5,d1.l),d4                ; B
        lsl.w   #8,d4
        subq.w  #1,d1
        move.b  (a5,d1.l),d4                ; C
        move.l  d1,d6
        DSSET
        DORET
        NEXT

        ifd     TRACE
trace_klog:
        move.l  a2,-(sp)
        movea.l trace_inp,a2
        cmpa.l  #trace_in+262144,a2
        bcc.s   .f
        move.b  d2,(a2)+
        move.l  a2,trace_inp
.f:     movea.l (sp)+,a2
        rts
        endif

; Port output.  d0.b = port low byte, d1 = high byte, d2.b = value.
; TODO: the beeper toggles on any access to port 0xFE (drive the YM2149).
out_port:
        rts

; 50 Hz service.  Entered by jump from CHKINT / HALT with the Z80 PC already
; advanced; ends by continuing the dispatch loop.
do_int:
        clr.b   ST_INT(a6)
        jsr     host_service
        tst.b   ST_IFF1(a6)
        beq.s   .no
        clr.b   ST_IFF1(a6)
        clr.b   ST_IFF2(a6)
        move.l  a0,d0
        sub.l   a5,d0
        PUSH16  d0,d2
        lea     $38(a5),a0                  ; IM 1 vector
        ifd     TRACE
        st      trace_intf
        endif
.no:    NEXT

        ifd     TRACE
; Trace build (vasm -DTRACE=<records>): after every instruction store
; PC,SP,A,F(S Z PV C),BC,DE,HL,IX,IY,int-taken,pad (18 bytes, big endian);
; when the buffer is full write TRACE.BIN and quit.  Compared on the host by
; test/oracle (xAce's Z80 core).
trace_rec:
        movem.l d0/a2,-(sp)
        move.l  trace_cnt,d0
        addq.l  #1,trace_cnt
        cmp.l   #TRACESKIP,d0
        bcc.s   .rec
        tst.b   trace_intf                  ; before the window: a full
        beq.s   .ret                        ; record at every interrupt
        movea.l trace_evp,a2
        cmpa.l  #trace_ev+TRACEEVB,a2
        bcc.s   .ret
        move.l  d0,(a2)+                    ; record number
        move.b  1(a1),(a2)+                 ; interrupted PC (pushed)
        move.b  (a1),(a2)+
        bsr.s   trace_put
        move.l  a2,trace_evp
.ret:   clr.b   trace_intf
        movem.l (sp)+,d0/a2
        rts
.rec:   movea.l trace_ptr,a2
        bsr.s   trace_put
        move.l  a2,trace_ptr
        cmpa.l  trace_end,a2
        bcc.s   trace_done
        movem.l (sp)+,d0/a2
        rts

; 18-byte record at (a2)+, clears the interrupt flag.  Clobbers d0.
trace_put:
        move.l  a0,d0
        sub.l   a5,d0
        move.w  d0,(a2)+
        move.l  a1,d0
        sub.l   a5,d0
        move.w  d0,(a2)+
        move.b  d7,(a2)+
        moveq   #$0f,d0
        and.w   d3,d0
        move.b  .ftab(pc,d0.w),(a2)+
        move.w  d4,(a2)+
        move.w  d5,(a2)+
        move.w  d6,(a2)+
        move.w  ST_IX(a6),(a2)+
        move.w  ST_IY(a6),(a2)+
        move.b  trace_intf,(a2)+
        clr.b   trace_intf
        clr.b   (a2)+
        rts
.ftab:  dc.b    $00,$01,$04,$05,$40,$41,$44,$45
        dc.b    $80,$81,$84,$85,$c0,$c1,$c4,$c5
trace_done:
        clr.w   -(sp)
        pea     tracename
        move.w  #$3c,-(sp)                  ; Fcreate
        trap    #1
        addq.l  #8,sp
        move.w  d0,d4
        bmi     .x
        move.l  trace_buf,-(sp)
        move.l  trace_ptr,d0
        sub.l   trace_buf,d0
        move.l  d0,-(sp)
        move.w  d4,-(sp)
        move.w  #$40,-(sp)                  ; Fwrite
        trap    #1
        lea     12(sp),sp
        move.w  d4,-(sp)
        move.w  #$3e,-(sp)                  ; Fclose
        trap    #1
        addq.l  #4,sp
        clr.w   -(sp)                       ; TRACEINT.BIN: interrupt points
        pea     tracename2                  ; before the window
        move.w  #$3c,-(sp)
        trap    #1
        addq.l  #8,sp
        move.w  d0,d4
        bmi     .x
        pea     trace_ev
        move.l  trace_evp,d0
        sub.l   #trace_ev,d0
        move.l  d0,-(sp)
        move.w  d4,-(sp)
        move.w  #$40,-(sp)                  ; Fwrite
        trap    #1
        lea     12(sp),sp
        move.w  d4,-(sp)
        move.w  #$3e,-(sp)                  ; Fclose
        trap    #1
        addq.l  #4,sp
        clr.w   -(sp)                       ; TRACEMEM.BIN: Z80 memory
        pea     tracename3
        move.w  #$3c,-(sp)
        trap    #1
        addq.l  #8,sp
        move.w  d0,d4
        bmi     .x
        move.l  a5,-(sp)
        move.l  #65536,-(sp)
        move.w  d4,-(sp)
        move.w  #$40,-(sp)                  ; Fwrite
        trap    #1
        lea     12(sp),sp
        move.w  d4,-(sp)
        move.w  #$3e,-(sp)                  ; Fclose
        trap    #1
        addq.l  #4,sp
        clr.w   -(sp)                       ; TRACEIN.BIN: port reads
        pea     tracename4
        move.w  #$3c,-(sp)
        trap    #1
        addq.l  #8,sp
        move.w  d0,d4
        bmi.s   .x
        pea     trace_in
        move.l  trace_inp,d0
        sub.l   #trace_in,d0
        move.l  d0,-(sp)
        move.w  d4,-(sp)
        move.w  #$40,-(sp)                  ; Fwrite
        trap    #1
        lea     12(sp),sp
        move.w  d4,-(sp)
        move.w  #$3e,-(sp)                  ; Fclose
        trap    #1
        addq.l  #4,sp
.x:     jmp     shutdown
        endif

; Unimplemented opcode: report PC and leave.
unimpl:
        move.l  a0,d0
        sub.l   a5,d0
        subq.w  #1,d0
        lea     badpc,a2
        lea     hexchars,a1
        moveq   #3,d2
.h:     rol.w   #4,d0
        move.w  d0,d1
        and.w   #$f,d1
        move.b  (a1,d1.w),(a2)+
        dbra    d2,.h
        pea     badmsg
        move.w  #9,-(sp)                    ; Cconws
        trap    #1
        addq.l  #6,sp
        move.w  #8,-(sp)                    ; Cnecin
        trap    #1
        addq.l  #2,sp
        jmp     shutdown

; ---------------------------------------------------------------------------
; The handlers: main opcodes in 256-byte slots around slot_mid (64K), then
; the prefix handlers and their address tables.
; ---------------------------------------------------------------------------
        include "z80ops.s"

        include "tables.s"
