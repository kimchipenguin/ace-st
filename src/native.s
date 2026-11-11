; ---------------------------------------------------------------------------
; Native Forth words.  fn_hl (the end of forth_next and of the ROM's NEXT
; at 04BA) looks the code address of the next word up in natab and runs
; these instead of the Z80 code.  Each one leaves the registers, the S Z PV
; C flags, the data stack (pointer at 3C3B) and the bytes below the Z80 SP
; (return addresses of RST / CALL) as the ROM code does, so the xAce trace
; oracle can check them (test/oracle/oracle.c runs the ROM code up to the
; word's JP (IY), or up to the JP (HL) at 04C5 for words that end in NEXT).
; -DNONATIVE leaves them out.
; GPL v2 or later.
; ---------------------------------------------------------------------------

        ifnd    NONATIVE

; fill natab from the list at the end
native_init:
        lea     natab,a0
        move.w  #8192-1,d0
.clr:   clr.l   (a0)+
        dbra    d0,.clr
        lea     natab,a0
        lea     natlist,a1
.set:   move.w  (a1)+,d0
        bmi.s   .done
        lsl.w   #2,d0
        move.l  (a1)+,(a0,d0.w)
        bra.s   .set
.done:  rts

; \1 = offset from the Z80 SP, \2 = destination word register
RDSP    macro
        move.b  \1+1(a1),-(sp)
        move.w  (sp)+,\2
        move.b  \1(a1),\2
        endm

; return address left below SP by RST / CALL (\1 = the address)
LEFT    macro
        move.b  #(\1)&$ff,-2(a1)
        move.b  #(\1)>>8,-1(a1)
        endm

; d5 = word at d1 (data stack)
RDDE    macro
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d5
        move.b  (a5,d1.l),d5
        endm

; write d5 to d1 / d1+1 through STORE; d1 ends at d1+1
WRDE    macro
        move.b  d5,d2
        STORE
        addq.w  #1,d1
        move.w  d5,-(sp)
        move.b  (sp)+,d2
        STORE
        endm

; RST 10: push d5 on the data stack; d6 = HL = new pointer, [3C3B] set
DSPUSH  macro
        DSPTR
        cmp.w   #$4000,d1
        bcs     .lo\@
        cmp.w   a3,d1                       ; last RAM byte or above
        bcc     .gen\@
        move.b  d5,(a5,d1.l)
        move.w  d5,-(sp)
        move.b  (sp)+,1(a5,d1.l)
        bra     .set\@
.lo\@:  WRDE
        subq.w  #1,d1
        bra     .set\@
.gen\@: WRDE
        subq.w  #1,d1
.set\@: addq.w  #2,d1
        move.l  d1,d6
        DSSET
        endm

; JP (IY): with IY = 04C8 straight into forth_next (trace and count builds
; still record that step)
NJPIY   macro
        moveq   #0,d0
        move.w  ST_IY(a6),d0
        lea     (a5,d0.l),a0
        cmp.w   #$04c8,d0
        bne.s   .n\@
        ifd     TRACE
        jsr     trace_rec
        endif
        ifd     ICOUNT
        addq.l  #1,icount
        endif
        addq.l  #2,a0
        jmp     forth_next
.n\@:   NEXT
        endm

; ROM NEXT at 04BA with HL = IP (d6): W = (IP), PUSH IP+2, then fn_hl
nat_next:
        move.l  d6,d1
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d2
        move.b  (a5,d1.l),d2
        addq.w  #2,d1
        move.w  d1,-(sp)                    ; PUSH HL
        move.b  (sp)+,-(a1)
        move.b  d1,-(a1)
        moveq   #0,d6
        move.w  d2,d6
        jmp     fn_hl

; C@ (0898): RST 18, LD A,(DE), LD E,A, LD D,0, RST 10, JP (IY)
nat_cfetch:
        DSPTR
        subq.w  #2,d1
        RDDE                                ; DE = address
        moveq   #0,d0
        move.b  (a5,d5.l),d0                ; LD A,(DE)
        move.b  d0,d7
        move.w  d0,d5                       ; DE = 00 A
        WRDE                                ; pushed back where it was
        addq.w  #1,d1
        move.l  d1,d6                       ; HL = pointer (unchanged)
        LEFT    $089e
        NJPIY

; C! (08A7): RST 18, CALL 084E (pop BC), LD A,C, LD (DE),A, JP (IY)
nat_cstore:
        DSPTR
        subq.w  #2,d1
        RDDE                                ; DE = address
        subq.w  #2,d1
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d4
        move.b  (a5,d1.l),d4                ; BC = value
        move.l  d1,d6                       ; HL = pointer - 4
        DSSET
        move.b  d4,d7                       ; LD A,C
        move.b  d4,d2
        move.l  d5,d1
        STORE                               ; LD (DE),A
        LEFT    $08ab
        NJPIY

; I (12EB): POP BC, POP DE, PUSH DE, PUSH BC, RST 10, JP (IY)
nat_i:
        RDSP    0,d4                        ; BC = IP
        RDSP    2,d5                        ; DE = loop index
        DSPUSH
        LEFT    $12f0
        NJPIY

; 1- (0E21): RST 18, JR 0E2D: DEC DE, RST 10, JP (IY)
nat_1minus:
        DSPTR
        subq.w  #2,d1
        RDDE
        subq.w  #1,d5
        WRDE
        addq.w  #1,d1
        move.l  d1,d6                       ; HL = pointer (unchanged)
        LEFT    $0e2f
        NJPIY

; number literal (1013): LD B,1, POP HL (IP), DE = (IP), PUSH IP+2,
; RST 10, DJNZ (B = 0, not taken), JP (IY)
nat_lit:
        moveq   #0,d1
        RDSP    0,d1                        ; IP
        RDDE                                ; DE = the number
        addq.w  #2,d1
        move.b  d1,(a1)                     ; IP+2 back on the stack
        move.w  d1,-(sp)
        move.b  (sp)+,1(a1)
        DSPUSH
        and.w   #$00ff,d4                   ; B = 0
        LEFT    $101c
        NJPIY

; +LOOP runtime (133E): step from the data stack; return stack IP, index,
; limit.  RST 18, POP BC (IP), POP HL (index), AND A, ADC HL,DE, LD A,D,
; POP DE (limit), SCF, JP PE (overflow: leave), PUSH DE, PUSH HL, then the
; signed compare at 0C99 (CALL, so 1353 is left at the IP's place): go on
; while index < limit (step >= 0) or limit < index (step < 0).  Both ways
; PUSH BC, SBC A,A and JP 1294: go on = branch (POP HL, ADD HL,(offset)),
; leave = POP HL, skip the offset, drop index and limit.  Then NEXT at 04BA.
nat_ploop:
        DSPTR
        subq.w  #2,d1
        RDDE                                ; DE = step
        move.l  d1,d6
        DSSET
        LEFT    $133f
        RDSP    0,d4                        ; BC = IP
        RDSP    2,d6                        ; HL = index
        RDSP    4,d2                        ; limit
        move.w  d6,d0
        add.w   d5,d0                       ; ADC HL,DE (carry clear)
        bvs.s   .ovf
        move.b  d0,2(a1)                    ; PUSH HL: the new index
        move.w  d0,-(sp)
        move.b  (sp)+,3(a1)
        tst.w   d5
        bmi.s   .neg
        cmp.w   d2,d0
        blt.s   .loop                       ; index < limit
        bra.s   .end
.neg:   cmp.w   d0,d2
        blt.s   .loop                       ; limit < index
.end:   move.b  #$53,(a1)                   ; left by CALL 0C99
        move.b  #$13,1(a1)
.ovf:   addq.l  #6,a1                       ; index and limit dropped
        moveq   #-1,d7                      ; SBC A,A with carry: A = FF,
        moveq   #$19,d3                     ; S and C set
        move.w  d4,d6
        addq.w  #2,d6                       ; past the branch offset
        bra     nat_next
.loop:  addq.l  #2,a1                       ; IP popped again at 1278
        moveq   #0,d7                       ; SBC A,A: A = 0, Z
        moveq   #0,d1
        move.w  d4,d1
        move.b  1(a5,d1.l),-(sp)            ; branch offset at IP
        move.w  (sp)+,d0
        move.b  (a5,d1.l),d0
        addq.w  #1,d1
        add.w   d0,d1                       ; ADD HL,DE: carry into C
        bcc.s   .nc
        moveq   #$15,d3                     ; Z, C
        bra.s   .go
.nc:    moveq   #$04,d3                     ; Z
.go:    move.l  d1,d6
        bra     nat_next

; DOCOL (0EC3, code of every colon definition): EX DE,HL, JP 04BA
nat_docol:
        move.w  d5,d6                       ; HL = W+2
        bra     nat_next

; EXIT (04B8): POP HL, POP HL (the caller's IP), NEXT at 04BA
nat_exit:
        RDSP    2,d6
        addq.l  #4,a1
        bra     nat_next

natlist:
        dc.w    $0898
        dc.l    nat_cfetch
        dc.w    $08a7
        dc.l    nat_cstore
        dc.w    $12eb
        dc.l    nat_i
        dc.w    $0e21
        dc.l    nat_1minus
        dc.w    $1013
        dc.l    nat_lit
        dc.w    $133e
        dc.l    nat_ploop
        dc.w    $0ec3
        dc.l    nat_docol
        dc.w    $04b8
        dc.l    nat_exit
        dc.w    -1

        endif
