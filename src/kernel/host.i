; ---------------------------------------------------------------------------
; The kernel <-> front end interface (ACE.PRG: src/main.s, ACEGEM.APP: gem/).
;
; The front end provides
;   host_service   every 20 ms from do_int (jsr), all registers its own to
;                  save: draw the screen (REFRESH, render.s), menus, dialogs.
;                  May jmp z80_reset or snap_start instead of returning.
;   host_snd_on    d0.w = tone period (YM units of 8 us, 1..4095): start the
;                  BEEP tone.  Keeps all registers but d0.
;   host_snd_off   tone off.  Keeps all registers but d0.
;   host_exit      jmp: end of a trace run, or an unknown opcode (after the
;                  message): leave the program.
;   run_sp         (long) the stack the Ace runs on; z80_reset and
;                  snap_start start from it.
;   ticks200       (long) counted up at 200 Hz (Timer C), BEEP's clock.
;
; The kernel provides
;   native_init    fill natab (once, after the ROM is in mem)
;   z80_reset      jmp: power-on reset with ram_last RAM, runs the Ace
;   snap_read      a0 = file name: snapshot to snap_buf (d0.l 0 = fine)
;   snap_free, snap_start (jmp: run the snapshot in snap_buf)
;   key_event      d1.w = ST scancode, bit 7 = break
;   joy_update     after a change of joy_port (IKBD joystick bytes, 2 ports)
;   keys_up        all Ace keys up
;   tape_close     forget the open tape file (after tapename changed)
;   build_expand, REFRESH (macro), shadow, expand: the screen (render.s)
;   mem, state, keyrows, joy_map, tapename, ram_last, quit_flag, snap_buf
;
; In ACE.PRG the kernel runs in supervisor mode.  ACEGEM runs it in user
; mode: then every GETF (macros.s) must be patched to move ccr on 68010+.
; ---------------------------------------------------------------------------
