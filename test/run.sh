#!/bin/zsh
# usage: test/run.sh <name> <script> [hatari options...]
# Boots Hatari (ST, mono, TOS 1.04) with test/hd/<name> as drive C: and
# autostarts ACE.PRG.  ACE.ROM comes from the project, TAPE.ACE from
# TAPE=<file> (default testgame/AceInvaders-056.tap).
# EXTRA="<files>" copies more files to C:.
# TOS=<img> picks another TOS image, APP=<prg> another binary (ACETRACE.PRG).
# Script: one command per line:
#   wait <secs> | shot | key <hex scancode> | down/up <scancode>
#   type <text> (letters, digits, space, . + : * - = ; , / "; "_" = Return) | hold <scancode> <secs>
#   mem <addr> <len> (dump into the log) | dbg <debugger command>
#   ff on|off (fast-forward, e.g. for long waits; type at normal speed)
#   delay <secs> (pause after each command sent, default $KEYDELAY or 0.15)
P=${0:A:h:h}; name=$1 script=${2:A}; shift 2
hd=$P/test/hd/$name out=$P/test/shots
rm -rf $hd; mkdir -p $hd $out
cp ${APP:-$P/ACE.PRG} $hd/ACE.PRG
cp $P/ACE.ROM $hd/ACE.ROM
cp ${TAPE:-$P/testgame/AceInvaders-056.tap} $hd/TAPE.ACE
[[ -n $EXTRA ]] && cp $EXTRA $hd/   # more files, e.g. for the Control+O tape selector
tos=${TOS:-$HOME/Documents/ST/TOS v1.04 (1989)(Atari Corp)(Mega ST)(DE)[Rainbow TOS].img}
fifo=${TMPDIR:-/tmp}/acest-hatari-$name.fifo; rm -f $fifo
home=$P/test/.hatari-home; mkdir -p $home
HOME=$home hatari --tos $tos --machine st --monitor mono -d $hd \
  --auto "C:\\ACE.PRG" --cmd-fifo $fifo --sound off --fast-boot on \
  --confirm-quit off --statusbar off --log-level error "$@" \
  < /dev/null > $out/$name.log 2>&1 &
pid=$!
for i in {1..50}; do [[ -p $fifo ]] && break; sleep 0.2; done
n=0; tmp=$(mktemp -d)
kd=${KEYDELAY:-0.15}
send() { echo "$1" > $fifo; sleep $kd; }
# ST scancodes (German TOS: Y/Z swapped on the keycaps, we send positions)
typeset -A sc; sc=(A 1e B 30 C 2e D 20 E 12 F 21 G 22 H 23 I 17 J 24 K 25 L 26
  M 32 N 31 O 18 P 19 Q 10 R 13 S 1f T 14 U 16 V 2f W 11 X 2d Y 15 Z 2c
  1 02 2 03 3 04 4 05 5 06 6 07 7 08 8 09 9 0a 0 0b " " 39 _ 1c)
# punctuation: Alt (= Ace Symbol Shift) + the Ace key
typeset -A sym; sym=(. 32 + 25 : 2c "*" 30 - 24 = 26 ";" 18 , 31 / 2f '"' 19)
while IFS= read -r line; do
  cmd=${line%% *}; rest=${line#* }; a=${rest%% *}; b=${rest#* }
  case $cmd in
    wait) sleep $a ;;
    shot) n=$((n+1)); send "hatari-debug screenshot $tmp/s.png"; sleep 1
          mv $tmp/s.png $out/$name-$n.png && echo "$out/$name-$n.png" ;;
    key)  send "hatari-event keypress $a" ;;
    down) send "hatari-event keydown $a" ;;
    up)   send "hatari-event keyup $a" ;;
    hold) send "hatari-event keydown $a"; sleep $b; send "hatari-event keyup $a" ;;
    type) for c in ${(s::)rest}; do
            if [[ -n $sym[$c] ]]; then
              send "hatari-event keydown 0x38"
              send "hatari-event keydown 0x$sym[$c]"; send "hatari-event keyup 0x$sym[$c]"
              send "hatari-event keyup 0x38"
            else
              send "hatari-event keydown 0x$sc[${(U)c}]"; send "hatari-event keyup 0x$sc[${(U)c}]"
            fi
          done ;;
    mem)  send "hatari-debug m $a $b" ;;
    dbg)  send "hatari-debug $rest" ;;
    ff)   send "hatari-option --fast-forward $a" ;;
    delay) kd=$a ;;
  esac
done < $script
echo "hatari-debug quit" > $fifo
for i in {1..25}; do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
kill $pid 2>/dev/null; rm -f $fifo
