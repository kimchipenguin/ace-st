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
nat_lp: RDSP    0,d4                        ; BC = IP
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

; LOOP runtime (1334): LD DE,1, JR 133F (into +LOOP after its RST 18)
nat_loop:
        moveq   #1,d5
        bra     nat_lp

; DOCOL (0EC3, code of every colon definition): EX DE,HL, JP 04BA
nat_docol:
        move.w  d5,d6                       ; HL = W+2
        bra     nat_next

; EXIT (04B8): POP HL, POP HL (the caller's IP), NEXT at 04BA
nat_exit:
        RDSP    2,d6
        addq.l  #4,a1
        bra     nat_next


; ---------------------------------------------------------------------------
; Words that Daleks uses most (profile of a few game turns in acetype)
; ---------------------------------------------------------------------------

; d5 = top of the data stack, d1 = its address (pointer - 2)
DSTOP   macro
        DSPTR
        subq.w  #2,d1
        RDDE
        endm

; d5 = word at d5 (16-bit address wrap, as LD E,(HL) / INC HL / LD D,(HL))
RDAT    macro
        moveq   #0,d0
        move.w  d5,d0
        move.b  (a5,d0.l),d5
        addq.w  #1,d0
        move.b  (a5,d0.l),-(sp)
        move.w  (sp)+,d0
        move.b  d5,d0
        moveq   #0,d5
        move.w  d0,d5
        endm

; \1 = offset from the Z80 SP, \2 = word register: write it there
WRSP    macro
        move.b  \2,\1(a1)
        move.w  \2,-(sp)
        move.b  (sp)+,\1+1(a1)
        endm

; DUP (086D): RST 18, RST 10, RST 10, JP (IY)
nat_dup:
        DSTOP
        DSPUSH
        LEFT    $0870
        NJPIY

; DROP (087B): RST 18, JP (IY)
nat_drop:
        DSTOP
        move.l  d1,d6
        DSSET
        LEFT    $087c
        NJPIY

; SWAP (0887): RST 18, CALL 084E, RST 10, LD D,B, LD E,C, RST 10, JP (IY)
nat_swap:
        DSTOP                               ; DE = top
        subq.w  #2,d1
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d4
        move.b  (a5,d1.l),d4                ; BC = second
        WRDE                                ; top where the second was
        addq.w  #1,d1
        move.w  d4,d5
        WRDE                                ; second on top
        addq.w  #1,d1
        move.l  d1,d6                       ; HL = pointer (unchanged)
        LEFT    $088f
        NJPIY

; @ (08B5): RST 18, EX DE,HL, LD E,(HL), INC HL, LD D,(HL), RST 10, JP (IY)
nat_fetch:
        DSTOP
        RDAT
        WRDE
        addq.w  #1,d1
        move.l  d1,d6
        LEFT    $08bb
        NJPIY

; ! (08C3): RST 18, CALL 084E, EX DE,HL, LD (HL),C, INC HL, LD (HL),B
nat_store:
        DSTOP                               ; DE = address
        subq.w  #2,d1
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d4
        move.b  (a5,d1.l),d4                ; BC = value
        move.l  d1,d6
        DSSET
        move.w  d6,-(sp)                    ; DE = pointer - 4
        move.l  d5,d1                       ; HL = address
        moveq   #0,d5
        move.w  (sp)+,d5
        move.b  d4,d2
        STORE
        addq.w  #1,d1
        move.w  d4,-(sp)
        move.b  (sp)+,d2
        STORE
        moveq   #0,d6
        move.w  d1,d6                       ; HL = address + 1
        LEFT    $08c7
        NJPIY

; >R (08D4): RST 18, POP BC, PUSH DE, PUSH BC, JP (IY)
nat_tor:
        DSTOP
        move.l  d1,d6
        DSSET
        LEFT    $08d5
        RDSP    0,d4                        ; BC = IP
        WRSP    0,d5
        subq.l  #2,a1
        WRSP    0,d4
        NJPIY

; R> (08E1): POP BC, POP DE, PUSH BC, RST 10, JP (IY)
nat_rfrom:
        RDSP    0,d4                        ; BC = IP
        RDSP    2,d5
        addq.l  #2,a1
        WRSP    0,d4
        DSPUSH
        LEFT    $08e5
        NJPIY

; ?DUP (08F0): RST 18, RST 10, LD A,D, OR E, CALL NZ,0010, JP (IY)
nat_qdup:
        DSTOP
        addq.w  #2,d1
        move.l  d1,d6                       ; HL = pointer
        move.w  d5,-(sp)
        move.b  (sp)+,d7                    ; A = D
        or.b    d5,d7                       ; OR E
        GETF    d3
        PAR     d7
        tst.b   d7
        beq     .z
        DSPUSH
        LEFT    $08f7
        NJPIY
.z:     LEFT    $08f2
        NJPIY

; 0= (0C1C): RST 18, LD A,D, OR E, CP 1, LD A,0, LD D,A, RLA, LD E,A,
; RST 10, JP (IY)
nat_zeq:
        DSTOP
        move.w  d5,-(sp)
        move.b  (sp)+,d2
        or.b    d5,d2
        cmp.b   #1,d2
        GETF    d3                       ; S Z PV of CP 1
ZRES:   moveq   #1,d7
        and.b   d3,d7                       ; RLA: A = carry,
        and.b   #$0e,d3                     ; carry = 0
        moveq   #0,d5
        move.b  d7,d5
        WRDE
        addq.w  #1,d1
        move.l  d1,d6
        LEFT    $0c27
        NJPIY

; 0< (0C30): RST 18, RL D, JR 0C21 (as 0=)
nat_zless:
        DSTOP
        move.w  d5,-(sp)
        move.b  (sp)+,d2
        SETX
        roxl.b  #1,d2
        GETF    d3
        PAR     d2
        bra     ZRES

; > (0C58): RST 18, PUSH DE, RST 18, POP HL, CALL 0C99, JR 0C21.
; 0C99: LD A,H, XOR D, JP M,0CA0, SBC HL,DE, 0CA0: RL H, RET.
nat_greater:
        DSTOP                               ; n2
        move.w  d5,d6
        subq.w  #2,d1
        RDDE                                ; DE = n1
        move.w  d6,d0
        eor.w   d5,d0
        bmi.s   .diff
        move.w  d6,d0
        sub.w   d5,d0                       ; SBC HL,DE (carry clear): X
        move.w  d0,-(sp)
        move.b  (sp)+,d2                    ; H
        roxl.b  #1,d2                       ; RL H
        bra.s   .fl
.diff:  move.w  d6,-(sp)                    ; XOR leaves carry clear
        move.b  (sp)+,d2
        lsl.b   #1,d2
.fl:    GETF    d3
        PAR     d2
        move.l  d1,d6                       ; pointer - 2
        addq.w  #2,d6
        DSSET
        move.b  #$5b,-4(a1)                 ; left by the second RST 18
        move.b  #$0c,-3(a1)
        bra     ZRES

; + (0DD4): RST 18, PUSH DE, RST 18, POP HL, ADD HL,DE, EX DE,HL, RST 10
nat_plus:
        DSTOP
        move.w  d5,d6
        subq.w  #2,d1
        RDDE
        add.w   d6,d5                       ; ADD HL,DE: carry only
        CFLAG
        WRDE
        addq.w  #1,d1
        move.l  d1,d6                       ; HL = pointer - 2
        DSSET
        move.b  #$d7,-4(a1)                 ; left by the second RST 18
        move.b  #$0d,-3(a1)
        LEFT    $0ddb
        NJPIY

; OR (0E38) / AND (0E4D): RST 18, CALL 084E, LD A,E, OR C, LD E,A,
; LD A,D, OR B, LD D,A, RST 10, JP (IY).  Flags of the high byte.
nat_or:
        DSTOP
        subq.w  #2,d1
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d4
        move.b  (a5,d1.l),d4                ; BC
        or.w    d4,d5
        move.w  d5,-(sp)
        move.b  (sp)+,d7                    ; A = D
        tst.b   d7
        GETF    d3
        PAR     d7
        WRDE
        addq.w  #1,d1
        move.l  d1,d6
        DSSET
        LEFT    $0e43
        NJPIY

nat_and:
        DSTOP
        subq.w  #2,d1
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d4
        move.b  (a5,d1.l),d4
        and.w   d4,d5
        move.w  d5,-(sp)
        move.b  (sp)+,d7
        tst.b   d7
        GETF    d3
        PAR     d7
        WRDE
        addq.w  #1,d1
        move.l  d1,d6
        DSSET
        LEFT    $0e58
        NJPIY

; NEGATE (0DAB): LD BC,2, LD HL,(3C3B), AND A, SBC HL,BC, then two
; rounds of LD A,B, SBC A,(HL), LD (HL),A, INC HL, DEC C.  Ends with
; BC = 0, HL = pointer, A = high byte, Z set, S PV clear, C = borrow.
nat_negate:
        DSPTR
        moveq   #0,d2
        subq.w  #2,d1                       ; X = borrow of SBC HL,BC
        move.b  1(a5,d1.l),-(sp)            ; (moves keep X)
        move.w  (sp)+,d2
        move.b  (a5,d1.l),d2
        negx.w  d2
        GETF    d3
        and.b   #$11,d3
        or.b    #$04,d3
        move.w  d2,-(sp)
        move.b  (sp)+,d7                    ; A = high byte
        STORE
        addq.w  #1,d1
        move.b  d7,d2
        STORE
        addq.w  #1,d1
        move.l  d1,d6
        moveq   #0,d4                       ; BC = 0
        NJPIY

; CREATE / VARIABLE runtime (0FEC: JR 0FF0, 0FF0: RST 10, JP (IY)):
; push DE = the parameter field
nat_var:
        DSPUSH
        LEFT    $0ff1
        NJPIY

; CONSTANT runtime (0FF5): EX DE,HL, LD E,(HL), INC HL, LD D,(HL), RST 10
nat_const:
        RDAT
        DSPUSH
        LEFT    $0ffa
        NJPIY

; 0BRANCH (128F): CALL 084E, LD A,B, OR C, JR Z,1278 (BRANCH), POP HL,
; INC HL, INC HL, JP 04BA
nat_0branch:
        DSPTR
        subq.w  #2,d1
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d4
        move.b  (a5,d1.l),d4                ; BC = flag
        move.l  d1,d6
        DSSET
        LEFT    $1292
        move.w  d4,-(sp)
        move.b  (sp)+,d7
        or.b    d4,d7                       ; A = B | C
        GETF    d3
        PAR     d7
        tst.b   d7
        beq     nat_br
        RDSP    0,d6                        ; POP HL, skip the offset
        addq.l  #2,a1
        addq.w  #2,d6
        bra     nat_next

; BRANCH (1278): POP HL, LD E,(HL), INC HL, LD D,(HL), ADD HL,DE, JP 04BA
nat_branch:
nat_br: moveq   #0,d1
        RDSP    0,d1                        ; IP
        addq.l  #2,a1
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d5
        move.b  (a5,d1.l),d5                ; offset
        addq.w  #1,d1
        add.w   d5,d1                       ; ADD HL,DE: carry only
        CFLAG
        move.l  d1,d6
        bra     nat_next

; DO runtime (1325): CALL 084E, RST 18, POP HL, PUSH DE, PUSH BC, PUSH HL
nat_do:
        DSPTR
        subq.w  #2,d1
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d4
        move.b  (a5,d1.l),d4                ; BC = start
        subq.w  #2,d1
        RDDE                                ; DE = limit
        move.l  d1,d6
        DSSET
        RDSP    0,d6                        ; HL = IP
        WRSP    0,d5
        WRSP    -2,d4
        subq.l  #4,a1
        WRSP    0,d6
        NJPIY

; U* (0CAA): RST 18, CALL 084E, then DE * BC by 16 shift-and-add rounds
; (HL low, DE high), EX DE,HL, JR 0CF3: PUSH HL, RST 10 (low), POP DE,
; RST 10 (high).  The last round leaves Z, S PV clear and the carry of
; its ADD HL,BC (none if the bit was 0); A = 0.
nat_umul:
        DSTOP
        subq.w  #2,d1
        move.b  1(a5,d1.l),-(sp)
        move.w  (sp)+,d4
        move.b  (a5,d1.l),d4                ; BC
        move.l  d1,a2                       ; pointer - 4
        moveq   #0,d6                       ; HL
        moveq   #15,d2
.l:     moveq   #0,d3
        add.w   d6,d6
        addx.w  d5,d5
        bcc.s   .n
        add.w   d4,d6
        bcc.s   .n
        moveq   #1,d3
        addq.w  #1,d5
.n:     dbra    d2,.l
        or.b    #$04,d3                     ; Z (DEC A)
        moveq   #0,d7
        move.l  a2,d1
        move.w  d5,-(sp)                    ; high
        move.w  d6,d5
        WRDE                                ; low at pointer - 4
        addq.w  #1,d1
        move.w  (sp)+,d5
        WRDE                                ; high at pointer - 2
        addq.w  #1,d1
        move.l  d1,d6
        DSSET
        move.b  #$f5,-4(a1)                 ; left by the first RST 10
        move.b  #$0c,-3(a1)
        LEFT    $0cf7
        NJPIY

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
        dc.w    $086d
        dc.l    nat_dup
        dc.w    $087b
        dc.l    nat_drop
        dc.w    $0887
        dc.l    nat_swap
        dc.w    $08b5
        dc.l    nat_fetch
        dc.w    $08c3
        dc.l    nat_store
        dc.w    $08d4
        dc.l    nat_tor
        dc.w    $08e1
        dc.l    nat_rfrom
        dc.w    $08f0
        dc.l    nat_qdup
        dc.w    $0c1c
        dc.l    nat_zeq
        dc.w    $0c30
        dc.l    nat_zless
        dc.w    $0c58
        dc.l    nat_greater
        dc.w    $0dd4
        dc.l    nat_plus
        dc.w    $0e38
        dc.l    nat_or
        dc.w    $0e4d
        dc.l    nat_and
        dc.w    $0dab
        dc.l    nat_negate
        dc.w    $0fec
        dc.l    nat_var
        dc.w    $0ff0
        dc.l    nat_var
        dc.w    $0ff5
        dc.l    nat_const
        dc.w    $128f
        dc.l    nat_0branch
        dc.w    $1278
        dc.l    nat_branch
        dc.w    $1325
        dc.l    nat_do
        dc.w    $1334
        dc.l    nat_loop
        dc.w    $0caa
        dc.l    nat_umul
        dc.w    -1

        endif
