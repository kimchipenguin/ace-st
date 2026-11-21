ACE ST - A Jupiter ACE emulator for the Atari ST
------------------------------------------------

The Jupiter ACE was an obscure 8-bit computer released in 1982 by the British company Jupiter Cantab. It arrived in a crowded market, just a couple of months after the UK release of the ZX Spectrum.

The most notable feature of the machine is the choice of Forth as the integrated programming environment instead of the more common BASIC. Forth is a very powerful language and well-suited for a system with limited RAM. The hardware looks like a ZX81 with a ZX Spectrum keyboard. It's more powerful than the Zeddy though: The ACE has video memory, a beeper and graphics through redefinition of character tiles.

Supposedly only around 6000 units were manufactured across two models.

Why?
----
While the ACE is no clone of either the ZX81 oder Spectrum, it is often included by Spectrum/ZX81 emulators. That's not the case for the emulators available for the ST.

The inspiration for this emulator was the excellent ZX81 Emulator by Christian Zwerschke. I wanted to know if it's possible to create an emulator with AI assistance, that achieves almost full speed on an 8 MHz ST. It's a reverse approach of sz81, an emulator based on the SDL library that I'll try to make faster. It makes sense to learn from a "simple project" (this one) and carry over the lessons to sz81. Otherwise it'd been easier to add a Jupiter ACE mode to sz81.

What it does do
---------------
- emulate a Jupiter ACE in various RAM configurations
- runs in medium and high resolution
- supports tape files (.TAP) and snapshots (.ACE)
- beeper sound
- joystick support like ZX81 emulator
- RAM configuration: 3K, 19K, 35K, 51K
- show the Jupiter ACE keyboard with the HELP key
- ACEGEM.APP: the same emulator as a GEM program, in a window or full
  screen, in any resolution, also under MagiC and MiNT

Limitations
-----------
- not yet 100% on the ST
- ACE.PRG only runs in ST medium and high (ACEGEM.APP runs everywhere)
- no sound board emulation
- ACE.PRG has no speed limit for fast Ataris (ACEGEM.APP has one)

Example
-------
Keeping with the ACE theme, I included a 2026 port of the classic 1984 Macintosh game "Daleks"

License
-------
GPL-2.0.

Hotkeys
-------
HELP        Show the Jupiter ACE keyboard (image from EightyOne emulator)
UNDO        Show the settings dialog (or left mouse click)
Ctrl+O      Open a tape
Ctrl+Q      Quit program
Alt+T       Save screenshot (32k format)

ACEGEM.APP - the GEM version
---------------------------
ACEGEM.APP needs ACEGEM.RSC and ACE.ROM in its folder. It runs on any
68000-family Atari (ST to Falcon, TT, ARAnyM) in any resolution, also
under MagiC and MiNT. The Ace runs while its window is on top.

Ctrl+O      Open a tape
Ctrl+L      Load a snapshot (.ACE)
Ctrl+T      Save a screenshot (PNG, in the folder SCNSHT)
Ctrl+Q      Quit program
Ctrl+R      Reset the Ace
Ctrl+P      Pause
Ctrl+F      Full screen (Ctrl+F or UNDO goes back)
Ctrl+S      Settings: RAM size, joystick keys, speed limit
Ctrl+K      The Jupiter ACE keyboard in a window (click the keys)
Ctrl+W      Close the window on top

On fast machines the speed limit keeps the Ace at the speed of a real
one; it is on by default with a 68020 or faster CPU. You can drop a tape
or snapshot on the window or on the program.

Links & Resources
-----------------
https://www.mia-jaap.de/software         - My website
https://github.com/kimchipenguin/ace-st  - source of this emulator
https://www.atariuptodate.de             - all new software releases for the ST 

https://www.jupiter-ace.co.uk/           - Jupiter ACE Archive
https://lawrencewoodman.github.io/xAce/  - Important resource for this emulator

Version history
---------------
1.0     - ACEGEM.APP, the GEM version: window or full screen, any
          resolution, MagiC and MiNT, keyboard window, speed limit,
          iconify, drag & drop, sound also on the Falcon and ARAnyM

0.8     - settings dialog
        - save screenshot
        - load .ACE snapshots
        - sound
        - compatible with medium resolution
        - added sample game Daleks