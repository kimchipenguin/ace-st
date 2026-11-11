# ACE ST

Jupiter Ace emulator for the Atari ST, written in 68000 assembly (vasm, Motorola syntax).
Licence: GPL v2 or later (see `LICENSE`). Derived in part from xAce (Edward Patel; keyboard
matrix by Lawrence Woodman; Z80 semantics via xz81/xz80 by Russell Marks and Ian Collier).
The keyboard picture shown by the Help key is from EightyOne by Michael D Wynne (GPL v2 or
later, see `assets/README.md`). The Jupiter Ace ROM (`ACE.ROM`) is included, as in xAce; it
is not under the GPL, see `ROM.md`.

The Jupiter ACE is an 8-bit computer most notable for its use of Forth as a built-in
language.

![Ace Invaders running in ACE ST (Hatari, ST high)](docs/ace-invaders.png)

## Status (2026-11-11)

Assembles with vasm and runs in Hatari (ST high and ST medium; TOS 1.04, 2.06, EmuTOS). Boots to the Ace prompt, Forth
works (VLIST, arithmetic), and Ace Invaders loads from its .TAP (renamed TAPE.ACE: xAce's block
format is the same as .TAP) and plays.

- **Correctness:** checked against xAce's own Z80 core (`test/oracle`): boot (3M instructions)
  and in-game windows (150k instructions after 1.09M and 3M, with tape loading, typed keys and
  key chords before them, and two windows with 22 BEEPs) match register for register; registers also match at every
  interrupt before the window. Memory matches except undocumented bits of pushed flags.
- **Speed: about 85% of a real Ace** on an 8 MHz ST, in Ace Invaders (about 378 ACE-ST steps per
  frame, ~146 Z80 T-states each; an estimate, since the share of native words, which are long
  steps, moves between 16% and 26% of all steps over the game). Steps: ROM code ~15%, native keyboard scan ~19-21%, native
  Forth NEXT ~30%, native data stack ~37%, inline 1K RAM writes ~41%, leaner data stack ~45%,
  screen refresh only when video RAM changed, four cells per compare ~48%, leaner Forth
  NEXT ~50%, handler slots instead of a dispatch table ~52%, byte moves through the stack
  instead of 8-bit shifts and `JP (IY)` straight into `forth_next` ~56%, native Forth
  words ~85%.
- **Native keyboard scan:** `ED FE C9` at 0x0336 replaces the ROM routine (85 Z80 instructions,
  640 T-states per call; the game calls it about 3.7 times per frame) with 68000 code that
  returns the same registers and flags. `-DNOKBSCAN` keeps the ROM routine, for comparisons.
- **Native Forth NEXT:** every Forth primitive ends with `JP (IY)` to 0x04C8, which checks the
  data stack and free memory, tests BREAK (Shift+Space) and falls into NEXT at 0x04B9: about 36
  Z80 instructions (360 T-states). `ED FF` at 0x04C8 does all of it in one step and leaves the
  same registers, flags and stack bytes. When a check fails it runs only `LD BC,11` and goes on
  in the ROM, which then reports ERROR 1/2/3 itself. `-DNOFNEXT` keeps the ROM code. The usual
  case (dictionary pointer below 0xFFF5, even Z80 SP) uses word compares and word stack
  accesses; the other cases keep exact byte code.
- **Native data stack:** the ROM's Forth data stack routines (pointer at 0x3C3B) run as one step:
  `RST 10` (push DE, 9 Z80 instructions) and `RST 18` (pop DE) are native opcode handlers, as
  0x0010/0x0018 are ROM; `ED FB` at 0x084E pops BC (7). Same registers, memory and stack bytes.
  The new pointer goes straight to 0x3C3B and its three 1K RAM mirrors; a push writes plain
  RAM (0x4000 up) directly, or the 1K RAM and its mirrors through one address register; only
  pushes into ROM/video RAM or across a boundary use the checked stores.
- **Native Forth words:** after NEXT has found the next word's code address (`fn_hl`, shared by
  `forth_next` and the ROM's NEXT at 0x04BA), `natab` (one long per address below 0x2000) gives
  a 68000 routine for the busiest words in Ace Invaders: `C@`, `C!`, `I`, `1-`, number literal,
  the `+LOOP` runtime, DOCOL (start of every colon definition) and EXIT (`src/native.s`). Each
  leaves the registers, flags, data stack and the bytes below the Z80 SP as the ROM code does;
  words that end in `JP (IY)` go straight on into `forth_next`, the others into NEXT. In the game
  loop these words took most of the time. `-DNONATIVE` leaves them out.
- **1K RAM writes:** the STORE macro writes 0x3000-0x3FFF (Forth data stack, system variables)
  and its three mirrors inline; ROM, video and character RAM still go through `store_low`.
- **Screen refresh** (12.5 Hz): skipped unless video RAM (or character RAM, which redraws
  everything) was written since the last one; compares four cells at a time with a shadow copy
  and draws only the groups that differ.
- **Handler dispatch:** each main opcode handler starts at `slot_mid + 256 * (signed) opcode`
  (256-byte slots, 64K of code). NEXT reads the opcode into the high byte of `d0` and jumps
  through `a4`: 38 cycles, no table load (was 44). Handlers larger than a slot would go out of
  line (`OVERSIZE` in `tools/gen_z80.py`; none now). ACE.PRG grows to about 134 KB.
- **Byte moves:** the high byte of BC/DE/HL and 16-bit stack and immediate values go through
  the 68000 stack (a byte pushed on a7 lands in the high half of a word) instead of 8-bit
  shifts, which cost 22 cycles each: `PUT_H` 48 -> 24 cycles, `GET_H` 26 -> 16, `POP16`
  50 -> 32, `PUSH16` 42 -> 28. `SETX` (carry into X before `ADC`/`SBC`/`RL`/`RR`) is now
  `moveq`/`and`/`lsr`, 16 cycles instead of about 42.
- `JP (IY)` with IY = 0x04C8 (the end of every Forth primitive) runs `forth_next` at once
  instead of dispatching the `ED FF` there; trace and count builds still record that step.
- **Profile before native words** (`test/pcprof.py`, 800 samples): `forth_next` 22%, NEXT dispatch 20%,
  `ds_push` 14%, `ds_pop` 9%, `refresh_screen` 3%. Ace Invaders keeps its data stack in the 1K RAM, so most
  of `ds_push` is the mirror copies.
- **Sound:** the Ace's speaker is only driven by the ROM's BEEP (and the tape code), and Ace
  Invaders uses BEEP for its effects. `ED FA` at 0x0BAF (the head of BEEP's speaker loop, after
  its `DI`) plays the tone on YM2149 channel A instead: BEEP's period m (8·m µs) is YM tone
  period m, and the length is cycles × 8·m µs of real time, in 5 ms steps of `_hz_200`, while the
  Ace stands still as on the real machine (its 50 Hz ticks of that time are lost). Beeps under
  2.5 ms are silent. Space during a beep gives BREAK (ERROR 3) like the ROM loop; registers and
  flags end as at the loop's `EI`. `-DNOSOUND` keeps the (silent) ROM loop.
- `DJNZ $` delay loops (ROM interrupt routine, BEEP delay) finish in one step.
- Tape loads mirror bytes below 0x4000 like the real 1K RAM/video chips.
- **Control+O** opens the GEM file selector to pick the tape file (see Build and run).
- **Undo** or a **left mouse click** opens the settings dialog ("ACE-ST Options", GEM `form_do`-style loop, `ACE.RSC`, no CF-Lib): RAM size
  (3K, 19K, 35K, 51K), joystick keys (up, down, left, right, fire: click a box or press its
  cursor key/Insert, then press the Ace key), Tape file, Load snapshot, Reset, Quit, Load/Save
  parameters (`ACE.INF`) and Continue. Keys: Return/Undo continue, 2-5 RAM, T tape, S snapshot,
  R reset, Q quit, L load, W save. A changed RAM size asks for a reset (or keeps the old size).
- **Snapshots:** `.ace` files (Ace32/EightyOne format) load from the dialog or from the command
  line (`ACE.PRG GAME.ACE`; any other file named there becomes the tape). Files that store only
  0x2000-0x7FFF get the ROM main loop (0x04F7) as their return address.
- **ACE.INF** (read at startup, written by Save parameters), for example:
  `RAM 19K` and `JOYSTICK 7 6 5 8 0` (key names as in the dialog; `SPC`, `ENT` etc.).
- **ST medium:** 640x200, the Ace screen at half height; logo and keyboard pictures in 4 shades.
- **Help** shows the Jupiter Ace logo and keyboard (EightyOne's picture); any key, a mouse click
  or joystick fire goes back.
- Mouse buttons: the IKBD mouse is off while the Ace runs, so its buttons arrive as the fire
  buttons: left = port 0 (opens the dialog, not passed to the Ace), right = port 1, the same
  line as the joystick's fire button (so a right click presses the Ace's fire key, 0 by
  default). The right button can't open the dialog without taking fire away from the joystick.
- **Alt+T** saves the screen as `ACE_0001.DOO`, `ACE_0002.DOO`, ... in the current directory
  (Doodle: 32000 bytes, 640x400 mono; ST medium lines are doubled) and rings the bell. Alt is
  the Ace's Symbol Shift, so Alt+T no longer types `>`.
- Quit: the IKBD gets the joystick command before the mouse one (a joystick mode command turns
  the mouse off, so the other order left the desktop without a mouse); the text cursor stays off.
- Startup screen: the Jupiter Ace logo for 2 seconds; any key skips it.

## Sample game: Daleks

`examples/daleks.fs` is Daleks in Ace Forth (19K or more), after the 1984 Macintosh game by
Johan Strandberg. Two ready-made files sit next to it:

- `examples/DALEKS.ACE`: a snapshot at the game's title screen. Load it with **Undo > Load
  snapshot** or start `ACE.PRG DALEKS.ACE`.
- `examples/DALEKS.TAP`: the dictionary on tape. Pick it with **Control+O** (or Undo > Tape),
  then type `load daleks` and `daleks`.

Each move the Daleks step towards you; two that meet, or one that runs into a wreck, become a
wreck (10 points per Dalek). Level n has 5 + 5n Daleks (at most 100). Keys: Q W E / A D / Z X C
move, S waits, 5-8 also move (Ace cursor keys, so the joystick works with its default keys)
and 0 waits; T teleports, B is the baseball (once per level: destroys the Daleks next
to you), L is the last stand (wait until the level ends). A turn with 100 Daleks takes about
1.5 s on a real Ace, as Forth in the Ace ROM is slow; the program keeps the board in video RAM
and stores each Dalek as its screen address, so the turn needs no multiplications.

`make daleks` rebuilds both files with `tools/acetype`, a headless Ace (xAce's Z80 core and
the Ace ROM) that types a text file into the ROM key by key, stops at a line that leaves an
error in the input line, and writes what `SAVE` saves as a .TAP. `#` lines in its input are
commands: `#screen` (print the Ace screen), `#wait n` (frames), `#key c down up`, `#snap
file` (.ace snapshot), `#ram n`, `#noerr`. It is also handy for trying out Forth code.

## Testing

- `test/run.sh <name> <script>`: Hatari run with ACE.ROM and TAPE.ACE, scripted keys,
  screenshots in test/shots (`type`, `key`, `hold`, `wait`, `shot`, `dbg`, `ff on|off`).
- `make trace TRACESKIP=n TRACEN=m`, run ACETRACE.PRG with `--memsize 4`, then
  `test/oracle/oracle xAce/ace.rom test/hd/<name>/TRACE.BIN n test/hd/<name>/TRACEINT.BIN`.
  The trace build also logs port reads (TRACEIN.BIN) and Z80 memory (TRACEMEM.BIN).
  `TRACEFLAGS=-DFNTEST_ODD=1` / `-DFNTEST_WRAP=1` force `forth_next` through its rare odd-SP /
  dictionary-wrap code, so a normal trace checks those paths too.
- `make count`: ACECOUNT.PRG keeps instruction and 50 Hz frame counters for speed checks;
  `test/scripts/gcount.txt` reads them in the game (address from Hatari's `info basepage`:
  BSS start + offset of `icount` in a vasm `-L` listing; $43666 under TOS 1.04 right now).
- The oracle has its own tape loader with ACE-ST's rules: xAce's `tape_skip_block` seeks
  backwards at the end of the tape. Debug aids: `WATCH=addr`, `KBLOG=record`, `TAPELOG=1`.
  It runs the ROM code behind both native traps as one step and prints their counts. A native
  Forth word (the trace marks it in the record's pad byte) runs in the oracle up to the word's
  `JP (IY)`, or the `JP (HL)` at 0x04C5 for DOCOL, EXIT, `+LOOP` and literal; `NONATIVE=1` turns
  that off for traces of a `-DNONATIVE` build. The BEEP loop runs in the oracle up to its `EI`
  at 0x0BC4 with no key down (`NOSOUND=1` for a `-DNOSOUND` build; `BEEPLOG=1` lists each beep's
  period and length).
- `test/scripts/beep.txt`: a 3 s BEEP with YM register dumps (`dbg info ym`) during and after;
  `beepbrk.txt`: Space during a beep (ERROR 3); `beeptrace.txt`: BEEPs for the oracle (windows
  at `TRACESKIP=400000` and `800000` hold 2 and 20 beeps).
- `test/scripts/brk.txt`: stack underflow (ERROR 2), arithmetic, BREAK out of an endless loop
  (ERROR 3); `brktrace.txt` is the same for the oracle (`TRACESKIP=1500000`).
- Profile: `test/run.sh samp test/scripts/gsample.txt` takes 800 register dumps in the game,
  `test/pcprof.py <vasm -L listing> test/shots/samp.log` maps them to handlers (Hatari's own
  profiler sees nothing when driven through the command pipe). `delay <secs>` in a script
  changes the pause after each command.
- `test/scripts/tapesel.txt` (run with `TAPE=/dev/null EXTRA=<copy of the game named INVADERS>`):
  Control+O, type the name in the selector, load and start the game. `tapecancel.txt`: Control+O
  with an empty name keeps TAPE.ACE. TOS 1.04's selector has no Cancel key, so Cancel itself is
  untested here.
- `test/scripts/help.txt`: Help at the prompt and in the game (written when only Help closed the
  picture; now the first key does); Control+Q quits to the desktop.
- `test/scripts/daleks.txt` (run with `TAPE=examples/DALEKS.TAP`): loads and starts Daleks,
  teleport and last stand.
- `test/scripts/changes.txt` (run with `EXTRA=ACE.RSC`): Help closed by a right click and by a
  key, Alt+T screenshot, the dialog, Control+Q. `lclick.txt` (`EXTRA=ACE.RSC`): a left click
  opens the dialog; on the Help screen it closes the picture. Hatari 2.6 has no single left
  click command, so the rig's `lclick` is a double click. `medshot.txt` (`--monitor rgb --tos-res med`):
  Alt+T and Help in ST medium. The rig's `rclick` sends a right click.
- `test/scripts/logo.txt`: screenshots of the startup logo and the Help screen.
- `test/run.sh` copies every file named in `EXTRA` (space separated) to the test drive.
- `-DARGTEST` builds an ACE.PRG that acts as if started with `SNAP.ACE` on the command line
  (Hatari's `--auto` can't pass one); `-DJOYTEST` reads the joystick from pokes into `joy_port`.
- The settings dialog is tested in mono and medium on TOS 1.04 (RAM change + reset, joystick
  keys, ACE.INF save/load, snapshot load, not-a-snapshot alert, missing ACE.RSC alert, Quit).
- The rig's `type` sends punctuation (`. + : * - = ; , / "`) as Alt (= Symbol Shift) + key.

## Build and run

```
brew install hatari                  # plus vasm and vlink from sun.hasenbraten.de
make                                 # -> ACE.PRG
make run                             # Hatari, ST high (mono)
```

`ACE.ROM` (the 8 KB Jupiter Ace ROM, included; see `ROM.md`) must be next to `ACE.PRG`.
Tapes use `TAPE.ACE` in the same directory, in xAce's block format (a .TAP works as is). **Control+O** opens the GEM file
selector and makes the chosen file the tape for the next `LOAD`/`SAVE`; a name that does not
exist yet becomes a new, empty tape. A write-protected tape is opened read-only. Control+O needs
the AES, so it does nothing when ACE.PRG runs from the AUTO folder. At startup the Jupiter Ace logo shows for
2 seconds (any key skips it). **Help** shows the Ace
keyboard and stops the Ace until a key or mouse click. **Undo** or a left click opens the
settings dialog. **Alt+T** saves a screenshot (.DOO). **Control+Q** quits. Needs ST
high (640x400 mono) or ST medium (640x200). `ACE.RSC` (the settings
dialog) belongs next to ACE.PRG too; `make rsc` rebuilds it and `src/rsc.i` from
`tools/mkrsc.py` (this overwrites changes made with a resource editor).

## Layout

| File | Purpose |
|---|---|
| `tools/gen_z80.py` | Generates `src/z80ops.s` (all opcode handlers and tables) and `src/tables.s` (parity, keymap) |
| `src/macros.s` | Register allocation, dispatch, flag and operand macros |
| `src/z80core.s` | Store/mirroring, port I/O, 50 Hz interrupt delivery, support routines |
| `src/video.s` | 2x scaled mono blit from video and character RAM |
| `src/tape.s` | ROM-trap tape load/save via GEMDOS (`ED FC C9` at 0x18A7, `ED FD C9` at 0x1820), Control+O file selector |
| `src/z80core.s` `kb_scan` | Native ROM keyboard scan (`ED FE C9` at 0x0336) |
| `src/z80core.s` `forth_next` | Native Forth checks + NEXT (`ED FF` at 0x04C8) |
| `src/z80core.s` `ds_push` etc. | Native Forth data stack (`RST 10`, `RST 18`, `ED FB` at 0x084E) |
| `src/z80core.s` `beep` | BEEP on YM2149 channel A (`ED FA` at 0x0BAF) |
| `src/native.s` | Native Forth words, looked up in `natab` by `fn_hl` |
| `src/gem.s` | GEM sessions (enter/leave, mouse, file selector), .ace snapshot reader and start |
| `src/dialog.s` | Undo settings dialog, ACE.INF load/save |
| `tools/mkrsc.py` | Writes `ACE.RSC` and `src/rsc.i` |
| `tools/acetype.c` | Headless Ace that types Forth source in (`make daleks`); `tools/acekeys.inc` is xAce's key table |
| `examples/` | Daleks in Ace Forth, with tape and snapshot |
| `src/main.s` | Startup, logo screen, IKBD and Timer C handlers, Help keyboard picture, data |
| `tools/logo.sh` | Renders the logo in `assets/Jupiter ACE Logo.pdf` to `assets/logo.pbm` (448x103, 1 bit; needs Ghostscript and ImageMagick); `make` turns it into `src/logo.bin` |
| `tools/kbpic.py` | Converts `assets/keyboardJupiterAce.bmp` (EightyOne) to `src/kbpic.bin` (1 bit, 512x223) |

## Design

- Flat 64K array, byte accesses only (the 68000 faults on odd word access).
- Z80 PC and SP are host pointers; HL/DE/BC are 16-bit in data registers; A is `d7`.
- Z80 flags live as a 68000 CCR image in `d3` (S=N, Z=Z, P/V=V, C=C).
- Main opcodes dispatch to fixed 256-byte slots; prefix tables (CB, ED, DD, FD, DDCB) hold
  handler addresses.
- The 50 Hz tick is a flag from Timer C, sampled at taken branches, calls, returns and HALT.

## Known gaps

- No throttling (not needed until the core reaches 100% somewhere).
- H and N flags are not tracked, so `DAA` stops with an "unimplemented opcode" message.
  Also missing: `SLL`, `RLD`/`RRD`, block I/O, undocumented IXH/IXL, IM 2, R register.
- Sound only through BEEP: direct speaker toggling on port 0xFE (not used by the ROM outside
  BEEP and tape saving) is ignored.
- No ST low. No .TZX, no tape truncation on save. `LOAD` from an empty tape prints `Bytes:`
  over and over instead of waiting.
- Punctuation keys map by physical position to Symbol Shift combinations.
