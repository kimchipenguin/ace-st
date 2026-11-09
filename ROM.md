# The Jupiter Ace ROM

`ACE.ROM` is the 8 KB Jupiter Ace ROM (Jupiter Cantab, 1982; written by Steven Vickers and
Richard Altwasser). It is the same file that xAce distributes (`ace.rom`, MD5
`db6efdfd82cebdfbb493d85b1a5efc3c`).

The ROM is not covered by ACE ST's GPL licence. xAce includes it on the strength of a 1998
email from Paul Downham of Boldfield Computing to xAce's author: he replied that the ROM
listing had been given away and that he did not expect anyone to object to its use with an
emulator. The email is in xAce's repository as
[`boldcomp.email.txt`](https://github.com/epatel/xAce/blob/master/boldcomp.email.txt).

ACE.PRG patches a few ROM addresses in memory when it starts (tape traps and native
routines); the file itself is unchanged.
