\ DALEKS for the Jupiter Ace (19K or more), after the 1984 Macintosh game
\ by Johan Strandberg.  Ace Forth, typed in by tools/acetype (make daleks);
\ lines starting with a backslash are comments for acetype, not for the Ace.
\
\ Board 30x20 inside a border.  Each move the Daleks step towards you; two
\ that meet, or one that runs into a wreck, become a wreck.  Keys: Q W E /
\ A D / Z X C move, S waits, 5-8 move (Ace cursor keys, joystick), 0 waits,
\ T teleports, B baseball (once per level, kills the Daleks next
\ to you), L last stand (wait until the level ends).
\
\ The screen is the board: video RAM 2400 (9216) + 32 * row + column holds
\ 32 empty, 1 Dalek, 2 you, 3 wreck, 160 border (inverse space).  A Dalek
\ is its screen address in DP (0 = destroyed); no multiplications in the
\ turn, as * is slow in the Ace ROM.

: +! SWAP OVER @ + SWAP ! ;
: UPC DUP 96 > IF 32 - THEN ;

\ characters 1-4 (Dalek, you, wreck, caught): 8 bytes each at 2C00
: GLYPH 8 * 11264 + 8 0 DO SWAP OVER 7 + I - C! LOOP DROP ;
: GLYPHS
 56 127 56 124 84 124 214 254 1 GLYPH
 24 24 126 24 24 36 66 0 2 GLYPH
 0 0 16 56 108 254 186 255 3 GLYPH
 129 66 36 24 24 36 66 129 4 GLYPH ;

0 VARIABLE SEED
: RND SEED @ 2053 * 13849 + DUP SEED ! U* SWAP DROP ;

CREATE DP 200 ALLOT
0 VARIABLE ND
0 VARIABLE ALIVE
0 VARIABLE PA
0 VARIABLE PCOL
0 VARIABLE PROW
0 VARIABLE SCORE
0 VARIABLE BEST
0 VARIABLE LEVEL
0 VARIABLE BALL
0 VARIABLE DEAD
0 VARIABLE KILLS

\ board cell (x,y) -> screen address; a random empty cell
: CELL 32 * + 9249 + ;
: RCELL BEGIN 30 RND 20 RND CELL DUP C@ 32 = 0= WHILE DROP REPEAT ;
: NEAR DUP 31 AND PCOL @ - ABS 2 < SWAP -32 AND PROW @ - ABS 33 < AND ;
: GOTO 32 PA @ C! DUP PA ! DUP 31 AND PCOL ! DUP -32 AND PROW ! 2 SWAP C! ;

\ keys: Q W E A S D Z X C 5 6 7 8 0 and their screen offsets
CREATE KT 81 C, 87 C, 69 C, 65 C, 83 C, 68 C, 90 C, 88 C, 67 C,
53 C, 54 C, 55 C, 56 C, 48 C,
CREATE KO -33 , -32 , -31 , -1 , 0 , 1 , 31 , 32 , 33 ,
-1 , 32 , -32 , 1 , 0 ,
: KFIND -1 SWAP 14 0 DO DUP KT I + C@ = IF SWAP DROP I SWAP THEN LOOP DROP ;
: GETK BEGIN INKEY 0= UNTIL BEGIN INKEY ?DUP UNTIL ;

\ screen
: BORDER CLS 32 0 DO 160 9216 I + C! 160 9888 I + C! LOOP
 21 1 DO I 32 * 9216 + 160 OVER C! 160 SWAP 31 + C! LOOP
 0 2 AT ."  DALEKS " ;
: NUM DUP >R 22 SWAP AT SPACES 22 R> AT . ;
: LABELS 22 0 AT ." LEVEL" 22 9 AT ." LEFT" 22 18 AT ." SCORE" ;
: SHOW LEVEL @ 3 6 NUM ALIVE @ 4 14 NUM SCORE @ 6 24 NUM
 BALL @ IF 0 21 AT ."  BASEBALL " ELSE 10 0 DO 160 9237 I + C! LOOP THEN ;

\ the Daleks: take them off the board, step each (a cell that is not
\ empty becomes a wreck, also yours), then destroy the ones on a wreck
: KILL 10 SCORE +! -1 ALIVE +! 1 KILLS +! ;
: UNDRAW ND @ DUP + 0 DO DP I + @ ?DUP IF 32 SWAP C! THEN 2 +LOOP ;
: TOWARD DUP 31 AND PCOL @ SWAP - DUP IF 0< IF -1 ELSE 1 THEN THEN +
 DUP -32 AND PROW @ SWAP - DUP IF 0< IF -32 ELSE 32 THEN THEN + ;
: MOVES ND @ DUP + 0 DO DP I + DUP @ ?DUP IF TOWARD DUP ROT !
 DUP C@ 32 = IF 1 ELSE 3 THEN SWAP C! ELSE DROP THEN 2 +LOOP ;
: SETTLE ND @ DUP + 0 DO DP I + @ ?DUP IF C@ 3 = IF 0 DP I + ! KILL THEN
 THEN 2 +LOOP ;
: CRASH KILLS @ IF 300 40 BEEP THEN ;
: TURN 0 KILLS ! UNDRAW MOVES SETTLE CRASH PA @ C@ 2 = 0= DEAD ! SHOW ;
: ZAP ND @ DUP + 0 DO DP I + @ ?DUP IF DUP NEAR IF 32 SWAP C! 0 DP I + !
 KILL ELSE DROP THEN THEN 2 +LOOP 20 0 DO 40 I 2 * + 4 BEEP LOOP ;

\ levels: 5 + 5 * level Daleks (at most 100), none next to you
: PLACE BEGIN RCELL DUP NEAR WHILE DROP REPEAT 1 OVER C! ;
: SETUP BORDER LABELS LEVEL @ 5 * 5 + 100 MIN DUP ND ! ALIVE ! 1 BALL !
 15 10 CELL DUP PA ! GOTO ND @ DUP + 0 DO PLACE DP I + ! 2 +LOOP SHOW ;
: JINGLE 200 60 BEEP 150 60 BEEP 100 120 BEEP ;
: NEWLEVEL 1 LEVEL +! SETUP JINGLE ;

\ your moves
: TELE 15 0 DO 30 I 6 * + 6 BEEP LOOP 32 PA @ C! RCELL GOTO TURN ;
: SWING BALL @ IF 0 BALL ! ZAP TURN THEN ;
: DONE DEAD @ ALIVE @ 0= OR ;
: LAST BEGIN TURN DONE UNTIL ;
: WALK KFIND DUP 0< IF DROP ELSE DUP + KO + @ PA @ + DUP C@ DUP 32 = SWAP 2 = OR
 IF GOTO TURN ELSE DROP 400 30 BEEP THEN THEN ;
: DOKEY UPC DUP 84 = IF DROP TELE ELSE DUP 66 = IF DROP SWING ELSE
 DUP 76 = IF DROP LAST ELSE WALK THEN THEN THEN ;

\ the game
: OVERSND 12 0 DO 100 I 25 * + 30 BEEP LOOP ;
: PLAY 15403 @ SEED ! 0 SCORE ! 0 LEVEL ! 0 DEAD ! GLYPHS
 BEGIN NEWLEVEL BEGIN GETK DOKEY DONE UNTIL DEAD @ UNTIL
 4 PA @ C! SCORE @ BEST @ MAX BEST ! SHOW OVERSND ;
: TITLE CLS GLYPHS 1 9357 C! 2 9360 C! 3 9363 C!
 1 11 AT ." D A L E K S"
 2 11 AT ." by Mia Jaap"
 6 1 AT ." The Daleks are after you. Lure"
 7 1 AT ." them into each other or into"
 8 1 AT ." the wrecks to destroy them."
 11 3 AT ." Q W E   T teleport"
 12 3 AT ." A S D   B baseball"
 13 3 AT ." Z X C   L last stand"
 14 1 AT ." (S or 0 waits, 5-8 also move)"
 17 5 AT ." Best score " BEST @ .
 20 5 AT ." Press a key to play" ;
: DALEKS BEGIN TITLE GETK DROP PLAY 10 8 AT ."  Game over "
 11 8 AT ."  Again? Y/N " GETK UPC 78 = UNTIL CLS ;
