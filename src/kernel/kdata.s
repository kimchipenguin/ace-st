; ---------------------------------------------------------------------------
; Kernel data and BSS (included at the end of the front end's data).
; ---------------------------------------------------------------------------
        section data,data

joy_map:  dc.b  $08,$07,$06,$09,$0b         ; keys 7 6 5 8 0 (up down left
          even                              ; right fire), ACE.INF can change
tapename: dc.b  "TAPE.ACE",0                ; path of the tape file
          dcb.b 160,0
badmsg:   dc.b  "Unimplemented Z80 opcode, PC="
badpc:    dc.b  "0000",13,10,0
hexchars: dc.b  "0123456789ABCDEF"
tracename: dc.b "TRACE.BIN",0
tracename2: dc.b "TRACEINT.BIN",0
tracename3: dc.b "TRACEMEM.BIN",0
tracename4: dc.b "TRACEIN.BIN",0
          even

        section bss,bss

        even
mem:         ds.b 65536+64
state:       ds.b ST_SIZE+12
        even
keyrows:     ds.b 8                         ; $ff = key up, set at start
kbrows:      ds.b 8                         ; the keyboard's part
joyrows:     ds.b 8                         ; the joystick's part
joy_port:    ds.b 2                         ; IKBD joystick state, ports 0/1
joy_hdr:     ds.b 1                         ; $FE/$FF: next byte is a joystick
        even
run_sp:      ds.l 1                         ; the Ace's stack top (front end)
ticks200:    ds.l 1                         ; 200 Hz count (front end's Timer C)
tape_fh:     ds.w 1
tape_tmp:    ds.b 4
tape_eof:    ds.b 1
tape_hdr_done: ds.b 1
quit_flag:   ds.b 1
        even
ram_last:    ds.w 1                         ; last RAM address (see a3)
snap_buf:    ds.l 1                         ; unpacked snapshot (Malloc)
snap_len:    ds.l 1                         ; bytes in the file (from 2000)
RDBUF equ 2048
rd_buf:      ds.b RDBUF
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
shadow:      ds.b 768                       ; screen as last drawn (render.s)
expand:      ds.b 512                       ; byte -> bits doubled
        even
natab:       ds.l 8192                      ; native Forth words by ROM address
