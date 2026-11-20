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

void kernel_init(void);         /* once, with the ROM in ace_mem */
int  kernel_run(int snap);      /* until gem_frame() says GF_QUIT: 0;
                                   -1 = unknown opcode */
void kernel_keys_up(void);
void kernel_key(int scancode);  /* bit 7 = break */
void kernel_joy(int bits);      /* joystick 1, IKBD bits */
int  ace_snap_read(const char *name);

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

extern volatile unsigned char gk_down[128];  /* ST keys held (hooked) */
extern volatile unsigned char gk_ring[16];   /* Control + key make codes */
extern volatile unsigned char gk_rin;
extern volatile unsigned char gk_hooked;     /* 0xFF hooked, 1 going, 0 off */

int gem_frame(void);            /* called by the kernel every 20 ms */

#endif
