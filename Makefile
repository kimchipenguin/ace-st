# ACE-ST build: vasm (Motorola syntax) writes the TOS executable directly.
#   make            build ACE.PRG
#   make run        run in Hatari, ST high (mono); needs ACE.ROM next to ACE.PRG
#   make trace      ACETRACE.PRG (TRACEN records after TRACESKIP instructions)
#   make count      ACECOUNT.PRG (instruction + frame counters for speed)
#   make oracle     host checker for traces (xAce's Z80 core)
VASM   ?= $(HOME)/Develop/vasm-src/vasm/vasmm68k_mot
TRACEN ?= 150000
TRACESKIP ?= 0
HATARI ?= hatari

GEN = src/z80ops.s src/tables.s src/kbpic.bin
SRCS = $(wildcard src/*.s)

all: ACE.PRG

trace: ACETRACE.PRG
count: ACECOUNT.PRG

src/z80ops.s src/tables.s: tools/gen_z80.py
	python3 tools/gen_z80.py

src/kbpic.bin: tools/kbpic.py assets/keyboardJupiterAce.bmp
	python3 tools/kbpic.py assets/keyboardJupiterAce.bmp $@

ACE.PRG: $(SRCS) $(GEN)
	$(VASM) -Ftos -m68000 -Isrc -o $@ src/main.s

ACETRACE.PRG: $(SRCS) $(GEN) FORCE
	$(VASM) -Ftos -m68000 -Isrc -DTRACE=$(TRACEN) -DTRACESKIP=$(TRACESKIP) -o $@ src/main.s

ACECOUNT.PRG: $(SRCS) $(GEN)
	$(VASM) -Ftos -m68000 -Isrc -DICOUNT=1 -o $@ src/main.s

oracle: test/oracle/oracle
test/oracle/oracle: test/oracle/oracle.c xAce/src/z80ops.c
	cc -O1 -w -IxAce/src -o $@ test/oracle/oracle.c

run: ACE.PRG
	$(HATARI) --monitor mono --machine st --fast-boot true -d . ACE.PRG

clean:
	rm -f ACE.PRG ACETRACE.PRG ACECOUNT.PRG test/oracle/oracle

.PHONY: all trace count oracle run clean FORCE
FORCE:
