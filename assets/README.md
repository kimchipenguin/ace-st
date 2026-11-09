# Assets

`keyboardJupiterAce.bmp` is the Jupiter Ace keyboard picture from
[EightyOne](https://sourceforge.net/projects/eightyone-sinclair-emulator/), the emulator
for the Sinclair ZX range and the Jupiter Ace, version 1.41 (`Source/KBPics/`).
It is used unchanged here.

EightyOne is Copyright (C) 2003-2025 Michael D Wynne and is free software under the
GNU General Public License, version 2 or (at your option) any later version.
ACE ST uses the same licence; see `LICENSE` in the top directory.

`tools/kbpic.py` turns the picture into `src/kbpic.bin`, a 1-bit bitmap for ST high,
which the **Help** key shows.

`Jupiter ACE Logo.pdf` holds the Jupiter Ace logo (three versions). `tools/logo.sh`
renders the top one to `logo.pbm` (448x103, 1 bit, red stripes in black), which ACE ST
shows at startup and above the keyboard on the **Help** screen.
