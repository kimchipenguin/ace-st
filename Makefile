# ACE-ST build: vasm (Motorola syntax) writes the TOS executable directly.
#   make            build ACE.PRG
#   make run        run in Hatari, ST high (mono); with the included ACE.ROM
#   make trace      ACETRACE.PRG (TRACEN records after TRACESKIP instructions)
#   make count      ACECOUNT.PRG (instruction + frame counters for speed)
#   make oracle     host checker for traces (xAce's Z80 core)
#   make rsc        ACE.RSC + src/rsc.i from tools/mkrsc.py (overwrites edits)
#   make daleks     examples/DALEKS.TAP + DALEKS.ACE (Forth game, typed in by tools/acetype)
#   make gem        ACEGEM.APP, the GEM version (gem/, m68k-atari-mint-gcc)
VASM   ?= $(HOME)/Develop/vasm-src/vasm/vasmm68k_mot
TRACEN ?= 150000
TRACESKIP ?= 0
HATARI ?= hatari

GEN = src/kernel/z80ops.s src/kernel/tables.s src/kbpic.bin src/logo.bin src/kbmed.bin src/logomed.bin
SRCS = $(wildcard src/*.s src/kernel/*.s) src/rsc.i

all: ACE.PRG

trace: ACETRACE.PRG
count: ACECOUNT.PRG

src/kernel/z80ops.s src/kernel/tables.s: tools/gen_z80.py
	python3 tools/gen_z80.py

src/kbpic.bin: tools/kbpic.py assets/keyboardJupiterAce.bmp
	python3 tools/kbpic.py assets/keyboardJupiterAce.bmp $@

# logo: 448x103 PBM (tools/logo.sh renders it from the PDF); keep the bitmap body
src/logo.bin: assets/logo.pbm
	tail -c 5768 assets/logo.pbm > $@

# ST medium: half height, 4 shades (two bitplanes)
src/kbmed.bin: tools/medpic.py assets/keyboardJupiterAce.bmp
	python3 tools/medpic.py bmp assets/keyboardJupiterAce.bmp $@
src/logomed.bin: tools/medpic.py assets/logo-med.pgm
	python3 tools/medpic.py pgm assets/logo-med.pgm $@

ACE.PRG: $(SRCS) $(GEN)
	$(VASM) -Ftos -m68000 -Isrc -Isrc/kernel -o $@ src/main.s

ACETRACE.PRG: $(SRCS) $(GEN) FORCE
	$(VASM) -Ftos -m68000 -Isrc -Isrc/kernel -DTRACE=$(TRACEN) -DTRACESKIP=$(TRACESKIP) $(TRACEFLAGS) -o $@ src/main.s

ACECOUNT.PRG: $(SRCS) $(GEN)
	$(VASM) -Ftos -m68000 -Isrc -Isrc/kernel -DICOUNT=1 -o $@ src/main.s

# settings dialog: not part of "all", so changes made to ACE.RSC with a
# resource editor stay (src/rsc.i must keep matching its objects)
rsc:
	python3 tools/mkrsc.py ACE.RSC src/rsc.i

# headless Ace (xAce's Z80 core) that types Forth source in and saves it
tools/acetype: tools/acetype.c tools/acekeys.inc xAce/src/z80ops.c
	cc -O2 -w -IxAce/src -Itools -o $@ tools/acetype.c

daleks: examples/DALEKS.TAP
examples/DALEKS.TAP: examples/daleks.fs examples/daleks-save.txt tools/acetype ACE.ROM
	tools/acetype ACE.ROM $@ examples/daleks.fs examples/daleks-save.txt

oracle: test/oracle/oracle
test/oracle/oracle: test/oracle/oracle.c xAce/src/z80ops.c
	cc -O1 -w -IxAce/src -o $@ test/oracle/oracle.c

run: ACE.PRG
	$(HATARI) --monitor mono --machine st --fast-boot true -d . ACE.PRG

# ACEGEM.APP: gem/glue.s (kernel + glue) is assembled twice: the listing of
# the first run gives build/flagtab.i (tools/flagtab.py), the GETF sites
# that are patched to move ccr on 68010 and later.
CROSS   ?= m68k-atari-mint-
GB       = gem/build
GVFLAGS  = -Faout -mid=0 -m68000 -quiet -DGEMAPP -Isrc/kernel -I$(GB)
GCFLAGS  = -m68000 -O2 -fomit-frame-pointer -Wall -Igem -I$(GB)
KSRCS    = gem/glue.s $(wildcard src/kernel/*.s) src/kernel/kernel.i src/kernel/host.i

gem: ACEGEM.APP

$(GB)/glue1.lst: $(KSRCS)
	@mkdir -p $(GB)
	$(VASM) $(GVFLAGS) -L $@ -o $(GB)/glue1.o gem/glue.s

$(GB)/flagtab.i: $(GB)/glue1.lst tools/flagtab.py
	python3 tools/flagtab.py $< $@

$(GB)/glue.o: $(KSRCS) $(GB)/flagtab.i
	$(VASM) $(GVFLAGS) -DFLAGTAB -o $@ gem/glue.s

ACEGEM.RSC $(GB)/acegem_rsc.h: tools/mkgemrsc.py
	@mkdir -p $(GB)
	python3 tools/mkgemrsc.py ACEGEM.RSC $(GB)/acegem_rsc.h

$(GB)/%.o: gem/%.c gem/kernel.h gem/aesfix.h $(GB)/acegem_rsc.h
	@mkdir -p $(GB)
	$(CROSS)gcc $(GCFLAGS) -c $< -o $@

ACEGEM.APP: $(GB)/glue.o $(GB)/acegem.o $(GB)/aesfix.o ACEGEM.RSC
	$(CROSS)gcc -m68000 -Wl,--wrap=mt_wind_create_grect -o $@ $(GB)/acegem.o $(GB)/aesfix.o $(GB)/glue.o -lcflib -lgem -lz
	$(CROSS)strip $@
	$(CROSS)stack -s --size=32768 $@ >/dev/null
	$(CROSS)flags -S $@ >/dev/null

clean:
	rm -f ACE.PRG ACETRACE.PRG ACECOUNT.PRG ACEGEM.APP test/oracle/oracle tools/acetype
	rm -rf $(GB)

.PHONY: all trace count oracle rsc daleks run gem clean FORCE
FORCE:
