/*
 * ACEGEM - the ACE-ST kernel as seen from C (gem/glue.s)
 * GPL v2 or later.
 */

#ifndef KERNEL_H
#define KERNEL_H

/* offsets in ace_state (src/kernel/macros.s) */
#define ST_INT      13          /* set at 50 Hz by the Timer C hook */
#define ST_REDRAW   18          /* character RAM written: redraw all */
#define ST_VDIRTY   19          /* video RAM written */

/* what gem_frame() returns to the kernel */
enum { GF_GO, GF_RESET, GF_SNAP, GF_QUIT };

extern unsigned char ace_mem[];             /* 64K + 64 */
extern volatile unsigned char ace_state[];
extern unsigned char ace_shadow[];          /* 768: screen as drawn */
extern unsigned short ace_ram_last;         /* 3FFF .. FFFF */
extern volatile long ace_ticks200;
extern char ace_tapename[];                 /* 169 bytes */
extern void *ace_snap_buf;
extern unsigned char ace_joy_map[5];        /* ST scancodes: up down left right fire */
extern const char ace_keyname[128][4];      /* Ace key names by ST scancode */
extern volatile unsigned char ace_keyrows[8]; /* what the Ace reads, bit clear = down */

void kernel_init(void);         /* once, with the ROM in ace_mem */
int  kernel_run(int snap);      /* until gem_frame() says GF_QUIT: 0;
                                   -1 = unknown opcode */
void kernel_keys_up(void);
void kernel_key(int scancode);  /* bit 7 = break */
void kernel_joy(int bits);      /* joystick 1, IKBD bits */
int  ace_snap_read(const char *name);   /* 0, -1 read, -2 not one, -3 memory */
void kernel_tape_close(void);
void kernel_matrix(int row, int mask, int down);  /* one Ace key */

/* GETF sites, offsets from kernel_start: move.w sr,dn -> move.w ccr,dn */
extern unsigned short kernel_start[];
extern long kernel_flags[];
extern long kernel_nflags;

/* hooks, for Supexec */
long gk_timer_on(void);
long gk_timer_off(void);
long gk_ikbd_on(void);
long gk_ikbd_off(void);
long gk_flush030(void);
long gk_flush040(void);
void gk_expand(void);
void gk_refresh(void *screen, int medium);  /* ST high / medium, direct */

extern volatile unsigned char gk_down[128];  /* ST keys held (hooked) */
extern volatile unsigned char gk_ring[16];   /* Control + key, Undo make codes */
extern volatile unsigned char gk_rin;
extern volatile unsigned char gk_hooked;     /* 0xFF hooked, 1 going, 0 off */

/* speed limit (gem/speed.c): the kernel's dispatch tables */
extern unsigned char ace_slot_base[];       /* main opcode handlers, 256 bytes each */
extern void *ace_slots;                     /* a4: ace_slot_base + 0x8000 or stubs */
extern volatile long ace_budget;            /* T-states left in this frame */
extern void *ace_natab[8192];               /* native Forth words by ROM address */
extern void *ace_cb_table[256], *ace_dd_table[256], *ace_ed_table[256];
extern void *ace_fd_table[256], *ace_ddcb_table[256];
void gk_throttle(void);                     /* calls gem_throttle(), keeps registers */
void gem_throttle(void);

int gem_frame(void);            /* called by the kernel every 20 ms */
void gem_sound(long period);    /* BEEP: YM tone period, 0 = off */

#endif
