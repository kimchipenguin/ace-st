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

Limitations
-----------
- not yet 100% on the ST
- no support for resolutions other than ST medium and high
- no sound board emulation
- no speed throttle for fast Ataris

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

Links & Resources
-----------------
https://www.mia-jaap.de/software         - My website
https://github.com/kimchipenguin/ace-st  - source of this emulator
https://www.atariuptodate.de             - all new software releases for the ST 

https://www.jupiter-ace.co.uk/           - Jupiter ACE Archive
https://lawrencewoodman.github.io/xAce/  - Important resource for this emulator

Version history
---------------
0.8     - settings dialog
        - save screenshot
        - load .ACE snapshots
        - sound
        - compatible with medium resolution
        - added sample game Daleks