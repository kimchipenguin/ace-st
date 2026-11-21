/*
 * ACEGEM - speed limit for fast machines.
 *
 * A real Ace runs 65000 Z80 T-states per 50 Hz frame (3.25 MHz).  With the
 * limit on, every dispatch goes through a stub that takes the T-states of
 * the instruction (or of the native Forth word) off ace_budget and waits
 * for the next 50 Hz tick when the frame's budget is used up.  The kernel
 * itself is unchanged: the stubs sit in front of its handlers, through
 * register a4 (main opcodes) and its prefix and native word tables.  With
 * the limit off nothing of this runs.
 *
 * The weights are the Z80's T-states; for the steps that ACE-ST runs as
 * one (native Forth words, the Forth NEXT, the data stack, the keyboard
 * scan, LDIR) they are what xAce's core counts for the ROM code they
 * replace (test/oracle with NATSTAT=1 on Daleks).
 * GPL v2 or later.
 */
#include <stdlib.h>
#include <string.h>
#include <mint/osbind.h>
#include <mint/mintbind.h>
#include <mint/cookie.h>
#include "kernel.h"
#include "speed.h"

#define FRAME_T 65000L              /* 3.25 MHz / 50 Hz */
#define FNEXT   361                 /* the Forth NEXT at 04C8 (JP (IY)) */
#define NATW    400                 /* a native word not in the list */

/* main opcodes; conditional jumps and calls: between taken and not */
static const unsigned char t_main[256] = {
	 4,10, 7, 6, 4, 4, 7, 4,  4,11, 7, 6, 4, 4, 7, 4,   /* 00 */
	10,10, 7, 6, 4, 4, 7, 4, 12,11, 7, 6, 4, 4, 7, 4,   /* 10 */
	10,10,16, 6, 4, 4, 7, 4, 10,11,16, 6, 4, 4, 7, 4,   /* 20 */
	10,10,13, 6,11,11,10, 4, 10,11,13, 6, 4, 4, 7, 4,   /* 30 */
	 4, 4, 4, 4, 4, 4, 7, 4,  4, 4, 4, 4, 4, 4, 7, 4,   /* 40 */
	 4, 4, 4, 4, 4, 4, 7, 4,  4, 4, 4, 4, 4, 4, 7, 4,   /* 50 */
	 4, 4, 4, 4, 4, 4, 7, 4,  4, 4, 4, 4, 4, 4, 7, 4,   /* 60 */
	 7, 7, 7, 7, 7, 7, 4, 7,  4, 4, 4, 4, 4, 4, 7, 4,   /* 70 */
	 4, 4, 4, 4, 4, 4, 7, 4,  4, 4, 4, 4, 4, 4, 7, 4,   /* 80 */
	 4, 4, 4, 4, 4, 4, 7, 4,  4, 4, 4, 4, 4, 4, 7, 4,   /* 90 */
	 4, 4, 4, 4, 4, 4, 7, 4,  4, 4, 4, 4, 4, 4, 7, 4,   /* A0 */
	 4, 4, 4, 4, 4, 4, 7, 4,  4, 4, 4, 4, 4, 4, 7, 4,   /* B0 */
	 8,10,10,10,14,11, 7,11,  8,10,10, 4,14,17, 7,11,   /* C0 */
	 8,10,10,11,14,11, 7,87,  8, 4,10,11,14, 4, 7,87,   /* D0: RST 10/18 = data stack */
	 8,10,10,19,14,11, 7,11,  8, 4,10, 4,14, 4, 7,11,   /* E0 */
	 8,10,10, 4,14,11, 7,11,  8, 6,10, 4,14, 4, 7,11,   /* F0 */
};

/* native Forth words (ROM code address): T-states of the ROM code up to
   its JP (IY) or JP (HL) at 04C5; + FNEXT where the native version goes
   on into forth_next itself (NJPIY) */
static const struct { unsigned short addr, t; } t_nat[] = {
	{ 0x0898, 204 + FNEXT }, { 0x08A7, 193 + FNEXT }, { 0x12EB, 139 + FNEXT },
	{ 0x0E21, 140 + FNEXT }, { 0x1013, 159 + FNEXT }, { 0x133E, 441 },
	{ 0x0EC3, 89 }, { 0x04B8, 95 }, { 0x086D, 275 + FNEXT },
	{ 0x087B, 97 + FNEXT }, { 0x0887, 368 + FNEXT }, { 0x08B5, 210 + FNEXT },
	{ 0x08C3, 206 + FNEXT }, { 0x08D4, 129 + FNEXT }, { 0x08E1, 128 + FNEXT },
	{ 0x08F0, 205 + FNEXT }, { 0x0C1C, 217 + FNEXT }, { 0x0C30, 222 + FNEXT },
	{ 0x0C58, 392 + FNEXT }, { 0x0DD4, 311 + FNEXT }, { 0x0E38, 295 + FNEXT },
	{ 0x0E4D, 295 + FNEXT }, { 0x0DAB, 140 + FNEXT }, { 0x0FEC, 109 + FNEXT },
	{ 0x0FF0, 97 + FNEXT }, { 0x0FF5, 110 + FNEXT }, { 0x128F, 229 },
	{ 0x1278, 126 }, { 0x1325, 225 + FNEXT }, { 0x1334, 374 },
	{ 0x0CAA, 1480 + FNEXT },
};

/* the prefix tables: T-states after the prefix's 4 */
static int t_cb(int op)
{
	if ((op & 7) != 6)
		return 4;
	return (op & 0xC0) == 0x40 ? 8 : 11;    /* BIT n,(HL) / the others */
}

/* ED: -1 = LDIR and friends, 21 per byte (BC, d4) */
static int t_ed(int op)
{
	if (op >= 0x40 && op < 0x80) {
		switch (op & 7) {
		case 0: case 1: return 8;               /* IN r,(C) / OUT (C),r */
		case 2: return 11;                      /* SBC / ADC HL,rr */
		case 3: return 16;                      /* LD (nn),rr / rr,(nn) */
		case 4: return 4;                       /* NEG */
		case 5: return 10;                      /* RETN / RETI */
		case 6: return 4;                       /* IM */
		default: return op == 0x67 || op == 0x6F ? 14 : 5;
		}
	}
	switch (op) {
	case 0xA0: case 0xA1: case 0xA2: case 0xA3:
	case 0xA8: case 0xA9: case 0xAA: case 0xAB:
		return 12;
	case 0xB0: case 0xB1: case 0xB8: case 0xB9:
		return -1;
	case 0xB2: case 0xB3: case 0xBA: case 0xBB:
		return 17;
	case 0xFA: return 0;                        /* BEEP: waits real time */
	case 0xFB: return 83;                       /* data stack: POP BC at 084E */
	case 0xFC: case 0xFD: return 0;             /* tape */
	case 0xFE: return 636;                      /* keyboard scan at 0336 */
	case 0xFF: return FNEXT - 4;                /* Forth NEXT at 04C8 */
	}
	return 4;
}

/* DD / FD with an IX / IY handler (else the main one, + 4 for the prefix) */
static int t_xy(int op, int iy)
{
	switch (op) {
	case 0x09: case 0x19: case 0x29: case 0x39: return 11;
	case 0x21: return 10;
	case 0x22: case 0x2A: return 16;
	case 0x23: case 0x2B: case 0xF9: return 6;
	case 0x34: case 0x35: return 19;
	case 0x36: return 15;
	case 0xCB: return 0;                        /* in the DDCB table */
	case 0xE1: return 10;
	case 0xE3: return 19;
	case 0xE5: return 11;
	case 0xE9: return iy ? 4 + FNEXT : 4;       /* JP (IY): Forth NEXT */
	}
	if ((op >= 0x40 && op < 0xC0 && (op & 7) == 6 && op != 0x76) ||
	    (op >= 0x70 && op < 0x78 && op != 0x76))
		return 15;                              /* (IX+d) */
	return t_main[op];
}

#define NSTUB 21                    /* words in a stub, at most */
#define NNAT  64                    /* native words, at most */

static unsigned char *stubs;                    /* 64K: a4 points into it */
static void *orig[5][256], *orig_nat[8192];
static short wt[5][256];                        /* prefix tables: 0 = no stub */
static unsigned short nat_stubs[NNAT][NSTUB];
static short nat_addr[NNAT], nnat;
static int on;
static long tick_wait;                          /* Syield() there (MiNT, MagiC) */

/* one stub at p: ace_budget -= t, gk_throttle() once below 0, on to h */
static unsigned short *stub(unsigned short *p, long t, void *h)
{
	unsigned long b = (unsigned long)&ace_budget;

	if (t < 0) {                                /* 21 T-states per byte */
		*p++ = 0x2F00;                          /* move.l d0,-(sp) */
		*p++ = 0x7000;                          /* moveq #0,d0 */
		*p++ = 0x3004;                          /* move.w d4,d0 */
		*p++ = 0xC0FC; *p++ = 21;               /* mulu.w #21,d0 */
		*p++ = 0x91B9;                          /* sub.l d0,b.l */
		*p++ = b >> 16; *p++ = b;
		*p++ = 0x4CDF; *p++ = 0x0001;           /* movem.l (sp)+,d0 */
	} else {
		*p++ = 0x04B9;                          /* sub.l #t,b.l */
		*p++ = t >> 16; *p++ = t;
		*p++ = b >> 16; *p++ = b;
	}
	*p++ = 0x6B06;                              /* bmi.s +6 */
	*p++ = 0x4EF9;                              /* jmp h.l */
	*p++ = (unsigned long)h >> 16; *p++ = (unsigned long)h;
	*p++ = 0x4EB9;                              /* jsr gk_throttle.l */
	*p++ = (unsigned long)gk_throttle >> 16; *p++ = (unsigned long)gk_throttle;
	*p++ = 0x4EF9;                              /* jmp h.l */
	*p++ = (unsigned long)h >> 16; *p++ = (unsigned long)h;
	return p;
}

static void flush(void)
{
	long cpu = 0;

	if (Getcookie(C__CPU, &cpu) != C_FOUND)
		cpu = 0;
	if (cpu == 20 || cpu == 30)
		Supexec(gk_flush030);
	else if (cpu >= 40)
		Supexec(gk_flush040);
}

/* the stubs: in the 256-byte slot of each opcode, the main one first, then
   those for the CB, DD, ED, FD and DDCB tables (42 bytes each at most) */
static int build(void)
{
	void **tab[5] = { ace_cb_table, ace_dd_table, ace_ed_table, ace_fd_table, ace_ddcb_table };
	int op, k;

	stubs = malloc(65536L);
	if (!stubs)
		return 0;
	for (k = 0; k < 5; k++)
		memcpy(orig[k], tab[k], sizeof orig[k]);
	memcpy(orig_nat, ace_natab, sizeof orig_nat);
	for (op = 0; op < 256; op++) {
		long slot = (long)(op ^ 0x80) << 8;
		unsigned char *s = stubs + slot;
		void *main_h = ace_slot_base + slot;

		for (k = 0; k < 5; k++) {
			void *h = orig[k][op];
			long t;

			switch (k) {
			case 0: t = t_cb(op); break;
			case 1: t = h == main_h ? t_main[op] : t_xy(op, 0); break;
			case 2: t = t_ed(op); break;
			case 3: t = h == main_h ? t_main[op] : t_xy(op, 1); break;
			default: t = (op & 0xC0) == 0x40 ? 16 : 19;   /* DDCB: BIT / others */
			}
			wt[k][op] = t;
			stub((unsigned short *)(s + 42 * (k + 1)), t, h);
		}
		/* the main one last: CB DD ED FD are the prefix's 4 */
		stub((unsigned short *)s, t_main[op], main_h);
	}
	for (op = 0; op < 8192 && nnat < NNAT; op++) {
		long t = NATW;
		unsigned j;

		if (!orig_nat[op])
			continue;
		for (j = 0; j < sizeof t_nat / sizeof t_nat[0]; j++)
			if (t_nat[j].addr == op)
				t = t_nat[j].t;
		stub(nat_stubs[nnat], t, orig_nat[op]);
		nat_addr[nnat++] = op;
	}
	return 1;
}

/* the limit on or off; between frames (gem_frame) or before kernel_run */
void speed_set(int want)
{
	void **tab[5] = { ace_cb_table, ace_dd_table, ace_ed_table, ace_fd_table, ace_ddcb_table };
	int op, k;
	long v;

	tick_wait = Getcookie(C_MiNT, &v) == C_FOUND || Getcookie(C_MagX, &v) == C_FOUND;
	if (want && !stubs && !build())
		want = 0;
	on = want;
	ace_budget = FRAME_T;
	if (!stubs)
		return;
	for (k = 0; k < 5; k++)
		for (op = 0; op < 256; op++)
			tab[k][op] = on && wt[k][op] ? stubs + ((long)(op ^ 0x80) << 8) + 42 * (k + 1)
			                             : orig[k][op];
	for (k = 0; k < nnat; k++)
		ace_natab[nat_addr[k]] = on ? (void *)nat_stubs[k] : orig_nat[nat_addr[k]];
	flush();
	ace_slots = on ? stubs + 0x8000 : ace_slot_base + 0x8000;
}

int speed_on(void)
{
	return on;
}

/* every 50 Hz frame: the next frame's T-states; what the last one took
   too many comes off (the stubs only look between instructions) */
void speed_frame(void)
{
	if (!on)
		return;
	ace_budget += FRAME_T;
	if (ace_budget > FRAME_T)
		ace_budget = FRAME_T;
}

/* the frame's T-states are used up: wait for the next tick */
void gem_throttle(void)
{
	while (!ace_state[ST_INT])
		if (tick_wait)
			Syield();
}
