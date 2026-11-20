/*
 * ACEGEM - the ACE-ST Jupiter Ace emulator as a GEM application
 *
 * The kernel (src/kernel, via gem/glue.s) runs the Ace in user mode, in
 * this program's own stack; every 20 ms of Ace time it calls gem_frame(),
 * which draws the screen into the window and handles the AES.
 *
 * Keys: while the window is on top, the keyboard processor's bytes go
 * straight to the Ace (an XBRA hook on Kbdvbase()->ikbdsys, as only that
 * gives the Ace key releases); Control + key is kept for the program.
 * TOS never sees the keys meanwhile, so the hook goes in only when no key
 * has come for longer than the key repeat delay (or TOS would repeat a key
 * whose release it never saw) and comes out only when all keys are up.
 * Without the 6850 ACIA (MagiC Mac/PC) the keys come as AES events and
 * count as held for a little while.
 *
 * GPL v2 or later.
 */

#include <gem.h>
#include <mint/osbind.h>
#include <mint/cookie.h>
#include <stdlib.h>
#include <string.h>
#include "kernel.h"

#define ACE_W   256
#define ACE_H   192
#define MAXS    8                   /* largest scale */

#define SC_Q    0x10
#define SC_CTRL 0x1D
#define SC_LSH  0x2A
#define SC_ALT  0x38

static short ap_id, vh, win = -1;
static short win_kind = NAME | CLOSER | MOVER | FULLER | SIZER;
static short pix_w = 1, pix_h = 1;          /* pixel shape, work_out[3/4] */
static GRECT desk, wwork, wfull_old;
static short fulled;
static char win_title[] = " ACEGEM ";

/* the picture: a one-plane bitmap, ACE_W * sx by ACE_H * sy */
static short sx, sy;                        /* 0 = does not fit */
static unsigned char *pic;
static short pic_rb;                        /* bytes per line */
static unsigned short wide_w[128 * MAXS];   /* (even, for sx = 2) */
#define wide ((unsigned char *)wide_w)        /* byte -> sx bytes */
static short ox, oy;                        /* picture in the window */
static short must_draw = 1;                 /* every cell again */

static short has_acia;
static long hold_first, hold_next;          /* AES keys: held for (ticks) */
static long held_until[128];
static long key_quiet;                      /* last AES key (ticks) */
static short want_quit;
static short skip;                          /* frames not drawn */
static short ev_div;

static long ticks(void)
{
	return ace_ticks200;
}

static void alert(const char *s)
{
	form_alert(1, s);
}

/* ---------------------------------------------------------------- */
/* the picture                                                       */
/* ---------------------------------------------------------------- */

static void make_wide(void)
{
	short v, b, k;

	memset(wide_w, 0, sizeof wide_w);
	for (v = 0; v < 256; v++)
		for (b = 0; b < 8; b++)
			if (v & (0x80 >> b))
				for (k = 0; k < sx; k++) {
					short bit = b * sx + k;
					wide[v * sx + (bit >> 3)] |= 0x80 >> (bit & 7);
				}
}

/* the largest sx, sy for w x h with the screen's pixel shape */
static void fit_scale(short w, short h, short *px, short *py)
{
	short x, y;

	for (y = h / ACE_H; y >= 1; y--) {
		if (y > MAXS)
			continue;
		x = (short)(((long)y * pix_h + pix_w / 2) / pix_w);
		if (x < 1)
			x = 1;
		if (x <= MAXS && (long)x * ACE_W <= w) {
			*px = x;
			*py = y;
			return;
		}
	}
	*px = *py = 0;
}

/* scale for the window's work area; a new bitmap when it changed */
static void set_scale(void)
{
	short nx, ny;

	fit_scale(wwork.g_w, wwork.g_h, &nx, &ny);
	if (nx == 0) {                      /* too small: 1x, cut off */
		nx = (short)((pix_h + pix_w / 2) / pix_w);
		if (nx < 1)
			nx = 1;
		ny = 1;
	}
	if (nx != sx || ny != sy || !pic) {
		free(pic);
		sx = nx;
		sy = ny;
		pic_rb = ACE_W / 8 * sx;
		pic = malloc((long)pic_rb * ACE_H * sy);
		if (!pic) {
			sx = sy = 1;
			pic_rb = ACE_W / 8;
			pic = malloc((long)pic_rb * ACE_H);
		}
		make_wide();
		must_draw = 1;
	}
	ox = (wwork.g_w - ACE_W * sx) / 2;
	oy = (wwork.g_h - ACE_H * sy) / 2;
	if (ox < 0)
		ox = 0;
	if (oy < 0)
		oy = 0;
}

/* one cell (code c) into pic at column col, character row row */
static void draw_cell(short col, short row, unsigned char c)
{
	const unsigned char *g = ace_mem + 0x2C00 + (c & 0x7F) * 8;
	unsigned char inv = (c & 0x80) ? 0xFF : 0;
	long rb = pic_rb, step = (long)sy * pic_rb;
	unsigned char *d = pic + (long)row * 8 * step + col * sx;
	short l, k;

	if (sy == 1 && sx == 1) {
		d[0] = g[0] ^ inv;
		d += rb;
		d[0] = g[1] ^ inv;
		d += rb;
		d[0] = g[2] ^ inv;
		d += rb;
		d[0] = g[3] ^ inv;
		d += rb;
		d[0] = g[4] ^ inv;
		d += rb;
		d[0] = g[5] ^ inv;
		d += rb;
		d[0] = g[6] ^ inv;
		d += rb;
		d[0] = g[7] ^ inv;
	} else if (sx == 2 && sy <= 2) {
		const unsigned short *w2 = (const unsigned short *)wide;

		for (l = 0; l < 8; l++, d += step) {
			unsigned short v = w2[(unsigned char)(g[l] ^ inv)];

			*(unsigned short *)d = v;
			if (sy == 2)
				*(unsigned short *)(d + rb) = v;
		}
	} else if (sx == 1) {
		for (l = 0; l < 8; l++, d += step)
			for (k = 0; k < sy; k++)
				d[k * rb] = g[l] ^ inv;
	} else if (sx == 2) {
		for (l = 0; l < 8; l++, d += step) {
			const unsigned char *w = wide + (unsigned char)(g[l] ^ inv) * 2;
			unsigned char *e = d;

			for (k = 0; k < sy; k++, e += rb) {
				e[0] = w[0];
				e[1] = w[1];
			}
		}
	} else {
		for (l = 0; l < 8; l++, d += step) {
			const unsigned char *w = wide + (unsigned char)(g[l] ^ inv) * sx;
			unsigned char *e = d;

			for (k = 0; k < sy; k++, e += rb)
				memcpy(e, w, sx);
		}
	}
}

/* character RAM as drawn: ST_REDRAW only means some glyph changed */
static unsigned long cram_shadow[256];

/* the cells that changed into pic; *top..*bot = character rows drawn */
static int render(short *top, short *bot)
{
	short i, all;
	const unsigned char *vram = ace_mem + 0x2400;
	unsigned char glyph_new[128];
	short any_glyph = 0;

	all = must_draw;
	if (!all && !ace_state[ST_REDRAW] && !ace_state[ST_VDIRTY])
		return 0;
	if (ace_state[ST_REDRAW] && !all) {
		const unsigned long *c = (const unsigned long *)(ace_mem + 0x2C00);
		unsigned long *o = cram_shadow;

		memset(glyph_new, 0, sizeof glyph_new);
		for (i = 0; i < 256; i++)
			if (c[i] != o[i]) {
				o[i] = c[i];
				glyph_new[i >> 1] = 1;
				any_glyph = 1;
			}
	}
	if (all)
		memcpy(cram_shadow, ace_mem + 0x2C00, 1024);
	ace_state[ST_REDRAW] = 0;
	ace_state[ST_VDIRTY] = 0;
	must_draw = 0;
	*top = 24;
	*bot = -1;
	if (!pic)
		return 0;
	for (i = 0; i < 768; i++) {
		unsigned char c = vram[i];
		short row;

		if (!all && ace_shadow[i] == c && !(any_glyph && glyph_new[c & 0x7F]))
			continue;
		ace_shadow[i] = c;
		row = i >> 5;
		if (row < *top)
			*top = row;
		if (row > *bot)
			*bot = row;
		draw_cell(i & 31, row, c);
	}
	return *bot >= 0;
}

static int intersect(const GRECT *a, GRECT *b)
{
	short x1 = a->g_x > b->g_x ? a->g_x : b->g_x;
	short y1 = a->g_y > b->g_y ? a->g_y : b->g_y;
	short x2 = a->g_x + a->g_w < b->g_x + b->g_w ? a->g_x + a->g_w : b->g_x + b->g_w;
	short y2 = a->g_y + a->g_h < b->g_y + b->g_h ? a->g_y + a->g_h : b->g_y + b->g_h;

	b->g_x = x1;
	b->g_y = y1;
	b->g_w = x2 - x1;
	b->g_h = y2 - y1;
	return b->g_w > 0 && b->g_h > 0;
}

/* screen area r (inside the work area): picture, black around it */
static void paint(const GRECT *r)
{
	GRECT p, c;
	short pxy[8], col[2] = { G_WHITE, G_BLACK };
	MFDB src, dst;

	pxy[0] = r->g_x;
	pxy[1] = r->g_y;
	pxy[2] = r->g_x + r->g_w - 1;
	pxy[3] = r->g_y + r->g_h - 1;
	vs_clip(vh, 1, pxy);

	p.g_x = wwork.g_x + ox;
	p.g_y = wwork.g_y + oy;
	p.g_w = ACE_W * sx;
	p.g_h = ACE_H * sy;

	/* the border: only what is outside the picture */
	c = *r;
	if (!pic || c.g_x < p.g_x || c.g_y < p.g_y ||
	    c.g_x + c.g_w > p.g_x + p.g_w || c.g_y + c.g_h > p.g_y + p.g_h) {
		vsf_interior(vh, FIS_SOLID);
		vsf_color(vh, G_BLACK);
		vswr_mode(vh, MD_REPLACE);
		vr_recfl(vh, pxy);
	}
	if (!pic)
		return;
	c = *r;
	if (!intersect(&p, &c))
		return;
	memset(&dst, 0, sizeof dst);
	src.fd_addr = pic;
	src.fd_w = pic_rb * 8;
	src.fd_h = ACE_H * sy;
	src.fd_wdwidth = pic_rb / 2;
	src.fd_stand = 0;
	src.fd_nplanes = 1;
	src.fd_r1 = src.fd_r2 = src.fd_r3 = 0;
	pxy[0] = c.g_x - p.g_x;
	pxy[1] = c.g_y - p.g_y;
	pxy[2] = pxy[0] + c.g_w - 1;
	pxy[3] = pxy[1] + c.g_h - 1;
	pxy[4] = c.g_x;
	pxy[5] = c.g_y;
	pxy[6] = c.g_x + c.g_w - 1;
	pxy[7] = c.g_y + c.g_h - 1;
	vrt_cpyfm(vh, MD_REPLACE, pxy, &src, &dst, col);
}

/* area (screen coordinates) through the window's rectangle list */
static void redraw(const GRECT *area)
{
	GRECT r, a = *area;
	short mx, my, mb, ks, mouse_off = 0;

	if (win < 0)
		return;
	if (!intersect(&desk, &a))
		return;
	wind_update(BEG_UPDATE);
	graf_mkstate(&mx, &my, &mb, &ks);
	if (mx >= a.g_x - 16 && mx < a.g_x + a.g_w + 16 &&
	    my >= a.g_y - 16 && my < a.g_y + a.g_h + 16) {
		graf_mouse(M_OFF, NULL);
		mouse_off = 1;
	}
	wind_get(win, WF_FIRSTXYWH, &r.g_x, &r.g_y, &r.g_w, &r.g_h);
	while (r.g_w > 0 && r.g_h > 0) {
		if (intersect(&a, &r))
			paint(&r);
		wind_get(win, WF_NEXTXYWH, &r.g_x, &r.g_y, &r.g_w, &r.g_h);
	}
	if (mouse_off)
		graf_mouse(M_ON, NULL);
	wind_update(END_UPDATE);
}

static void show_changes(void)
{
	short top, bot;
	GRECT a;

	if (!render(&top, &bot))
		return;
	a.g_x = wwork.g_x + ox;
	a.g_y = wwork.g_y + oy + top * 8 * sy;
	a.g_w = ACE_W * sx;
	a.g_h = (bot - top + 1) * 8 * sy;
	redraw(&a);
}

/* ---------------------------------------------------------------- */
/* the window                                                        */
/* ---------------------------------------------------------------- */

static void set_border(GRECT *b)
{
	GRECT old = wwork;

	if (b->g_w < 120)
		b->g_w = 120;
	if (b->g_h < 80)
		b->g_h = 80;
	wind_set(win, WF_CURRXYWH, b->g_x, b->g_y, b->g_w, b->g_h);
	wind_get(win, WF_WORKXYWH, &wwork.g_x, &wwork.g_y, &wwork.g_w, &wwork.g_h);
	set_scale();
	/* the picture moved inside the window: all of it again (moving the
	   window alone is the AES's job) */
	if (wwork.g_w != old.g_w || wwork.g_h != old.g_h) {
		render(&old.g_x, &old.g_y);
		redraw(&wwork);
	}
}

static int open_window(void)
{
	GRECT b, w;
	short px, py;

	wind_get(0, WF_WORKXYWH, &desk.g_x, &desk.g_y, &desk.g_w, &desk.g_h);
	/* the largest scale that fits on the desktop */
	wind_calc(WC_WORK, win_kind, desk.g_x, desk.g_y, desk.g_w, desk.g_h,
	          &w.g_x, &w.g_y, &w.g_w, &w.g_h);
	fit_scale(w.g_w, w.g_h, &px, &py);
	if (px == 0)
		px = py = 1;
	wind_calc(WC_BORDER, win_kind, 0, 0, ACE_W * px, ACE_H * py,
	          &b.g_x, &b.g_y, &b.g_w, &b.g_h);
	if (b.g_w > desk.g_w)
		b.g_w = desk.g_w;
	if (b.g_h > desk.g_h)
		b.g_h = desk.g_h;
	b.g_x = desk.g_x + (desk.g_w - b.g_w) / 2;
	b.g_y = desk.g_y + (desk.g_h - b.g_h) / 2;

	win = wind_create(win_kind, desk.g_x, desk.g_y, desk.g_w, desk.g_h);
	if (win < 0)
		return 0;
	wind_set_str(win, WF_NAME, win_title);
	wind_open(win, b.g_x, b.g_y, b.g_w, b.g_h);
	wind_get(win, WF_WORKXYWH, &wwork.g_x, &wwork.g_y, &wwork.g_w, &wwork.g_h);
	set_scale();
	return 1;
}

static int on_top(void)
{
	short top, d;

	if (win < 0)
		return 0;
	wind_get(0, WF_TOP, &top, &d, &d, &d);
	return top == win;
}

/* ---------------------------------------------------------------- */
/* keys                                                              */
/* ---------------------------------------------------------------- */

static int any_down(void)
{
	short i;

	for (i = 0; i < 128; i++)
		if (gk_down[i])
			return 1;
	return 0;
}

/* hook the keyboard processor when we may, unhook when we must */
static void keys_manage(int want)
{
	long now = ticks();

	if (!has_acia)
		return;
	if (want) {
		if (gk_hooked == 0xFF)
			return;
		if (gk_hooked == 1) {               /* was going: stay */
			gk_hooked = 0xFF;
			return;
		}
		if ((Kbshift(-1) & 0x0F) || now - key_quiet < hold_first)
			return;
		memset((void *)gk_down, 0, 128);
		gk_rin = 0;
		kernel_keys_up();
		Supexec(gk_ikbd_on);
		gk_hooked = 0xFF;
	} else if (gk_hooked) {
		gk_hooked = 1;                      /* no new keys */
		if (any_down())
			return;
		Supexec(gk_ikbd_off);
		gk_hooked = 0;
		kernel_keys_up();
		Kbshift(Kbshift(-1) & 0x10);        /* keep Caps Lock only */
	}
}

/* an AES key event (not hooked): the Ace sees it held for a while */
static void aes_key(short kstate, short kreturn)
{
	short sc = (kreturn >> 8) & 0x7F;
	long now = ticks();

	key_quiet = now;
	if (kstate & K_CTRL) {
		if (sc == SC_Q)
			want_quit = 1;
		return;
	}
	if (!on_top() || sc == 0)
		return;
	held_until[sc] = now + (held_until[sc] > now ? hold_next : hold_first);
	kernel_key(sc);
	if (kstate & (K_LSHIFT | K_RSHIFT)) {
		held_until[SC_LSH] = held_until[sc];
		kernel_key(SC_LSH);
	}
	if (kstate & K_ALT) {
		held_until[SC_ALT] = held_until[sc];
		kernel_key(SC_ALT);
	}
}

static void aes_keys_expire(void)
{
	short i;
	long now = ticks();

	for (i = 0; i < 128; i++)
		if (held_until[i] && now >= held_until[i]) {
			held_until[i] = 0;
			kernel_key(i | 0x80);
		}
}

static void ring_keys(void)
{
	static unsigned char rout;

	while (rout != gk_rin) {
		unsigned char sc = gk_ring[rout];

		rout = (rout + 1) & 15;
		if (sc == SC_Q)
			want_quit = 1;
	}
}

/* ---------------------------------------------------------------- */
/* events                                                            */
/* ---------------------------------------------------------------- */

static void message(short *msg)
{
	GRECT r;

	if (msg[3] != win && msg[0] != AP_TERM)
		return;
	switch (msg[0]) {
	case WM_REDRAW:
		r.g_x = msg[4];
		r.g_y = msg[5];
		r.g_w = msg[6];
		r.g_h = msg[7];
		redraw(&r);
		break;
	case WM_TOPPED:
		wind_set(win, WF_TOP, 0, 0, 0, 0);
		break;
	case WM_CLOSED:
	case AP_TERM:
		want_quit = 1;
		break;
	case WM_MOVED:
		r.g_x = msg[4];
		r.g_y = msg[5];
		r.g_w = msg[6];
		r.g_h = msg[7];
		fulled = 0;
		set_border(&r);
		break;
	case WM_SIZED:
		r.g_x = msg[4];
		r.g_y = msg[5];
		r.g_w = msg[6];
		r.g_h = msg[7];
		fulled = 0;
		set_border(&r);
		break;
	case WM_FULLED:
		if (fulled) {
			r = wfull_old;
			fulled = 0;
		} else {
			wind_get(win, WF_CURRXYWH, &wfull_old.g_x, &wfull_old.g_y,
			         &wfull_old.g_w, &wfull_old.g_h);
			r = desk;
			fulled = 1;
		}
		set_border(&r);
		break;
	}
}

/* one evnt_multi; block (paused) when wait */
static void events(int wait)
{
	short msg[8], mx, my, mb, ks, kr, br, ev;

	ev = evnt_multi(MU_MESAG | MU_KEYBD | (wait ? 0 : MU_TIMER),
	                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	                msg, 0, &mx, &my, &mb, &ks, &kr, &br);
	if (ev & MU_MESAG)
		message(msg);
	if (ev & MU_KEYBD)
		aes_key(ks, kr);
}

#ifdef STATS
static long st_t0, st_frames, st_ev, st_draw;
static char st_buf[64];

static void stats(void)
{
	long now = ticks();

	st_frames++;
	if (now - st_t0 >= 200) {
		char *p = st_buf;
		long v[3], i;

		v[0] = st_frames;
		v[1] = st_ev;
		v[2] = st_draw;
		*p++ = ' ';
		for (i = 0; i < 3; i++) {
			char t[12];
			short n = 0;
			long x = v[i];

			do t[n++] = '0' + x % 10; while ((x /= 10) != 0);
			while (n)
				*p++ = t[--n];
			*p++ = ' ';
		}
		*p = 0;
		wind_set_str(win, WF_NAME, st_buf);
		st_t0 = now;
		st_frames = st_ev = st_draw = 0;
	}
}
#endif

int gem_frame(void)
{
#ifdef STATS
	long t;

	stats();
	t = ticks();
#endif
	ring_keys();
	aes_keys_expire();
	if (skip > 0)
		skip--;
	else if (!want_quit) {
		/* drawing gets at most about a third of the time: after a draw
		   of n ticks (5 ms) the next n / 2 frames are not drawn */
		long t0 = ticks();

		show_changes();
		skip = (short)((ticks() - t0) / 2);
		if (skip > 4)
			skip = 4;
	}
#ifdef STATS
	st_draw += ticks() - t;
	t = ticks();
#endif
	/* an evnt_multi costs some 5 ms on an 8 MHz ST: every third frame */
	if (++ev_div >= 3 || want_quit) {
		ev_div = 0;
		events(0);
		/* not on top (a dialog, another program): the Ace waits */
		while (!want_quit && !on_top()) {
			keys_manage(0);
			events(1);
		}
		if (!want_quit)
			keys_manage(1);
	}
#ifdef STATS
	st_ev += ticks() - t;
#endif
	return want_quit ? GF_QUIT : GF_GO;
}

/* ---------------------------------------------------------------- */
/* start and end                                                     */
/* ---------------------------------------------------------------- */

static int acia_machine(void)
{
	long v;

	if (Getcookie(0x4D674D63L, &v) == C_FOUND ||     /* MgMc: MagiC Mac */
	    Getcookie(0x4D675043L, &v) == C_FOUND)       /* MgPC: MagiC PC */
		return 0;
	if (Getcookie(C__MCH, &v) != C_FOUND)
		return 1;
	return (v >> 16) <= 3;                          /* ST, STE, TT, Falcon */
}

static void patch_flags(void)
{
	long cpu = 0, i;

	if (Getcookie(C__CPU, &cpu) != C_FOUND || cpu < 10)
		return;                         /* 68000: move sr is fine */
	for (i = 0; i < kernel_nflags; i++) {
		unsigned short *p = kernel_start + kernel_flags[i] / 2;

		if ((*p & 0xFFF8) == 0x40C0)    /* move.w sr,dn */
			*p |= 0x0200;               /* move.w ccr,dn */
	}
	if (cpu == 20 || cpu == 30)
		Supexec(gk_flush030);
	else if (cpu >= 40)
		Supexec(gk_flush040);
}

static int load_rom(void)
{
	long fh = Fopen("ACE.ROM", 0), n;

	if (fh < 0)
		return 0;
	n = Fread((short)fh, 8192, ace_mem);
	Fclose((short)fh);
	return n == 8192;
}

int main(void)
{
	short work_in[11], work_out[57], d, i;
	long rate, v;

	ap_id = appl_init();
	if (ap_id < 0)
		return 1;
	if (Getcookie(0x5F43465FL, &v) == C_FOUND) {     /* _CF_: ColdFire */
		alert("[3][ACEGEM needs a 68000-family CPU.|"
		      "It does not run on ColdFire.][ OK ]");
		appl_exit();
		return 1;
	}
	graf_mouse(ARROW, NULL);
	vh = graf_handle(&d, &d, &d, &d);
	for (i = 0; i < 10; i++)
		work_in[i] = 1;
	work_in[10] = 2;
	v_opnvwk(work_in, &vh, work_out);
	if (vh <= 0) {
		appl_exit();
		return 1;
	}
	pix_w = work_out[3] > 0 ? work_out[3] : 1;
	pix_h = work_out[4] > 0 ? work_out[4] : 1;

	if (!load_rom()) {
		alert("[3][ACEGEM cannot read ACE.ROM|"
		      "(8192 bytes, next to the program).][ OK ]");
		v_clsvwk(vh);
		appl_exit();
		return 1;
	}
	ace_ram_last = 0xFFFF;                      /* 51K */
	kernel_init();
	patch_flags();

	has_acia = acia_machine();
	rate = Kbrate(-1, -1);
	hold_first = ((rate >> 8) & 0xFF) * 4 + 10; /* Kbrate counts 20 ms */
	hold_next = (rate & 0xFF) * 4 + 10;

	if (!open_window()) {
		alert("[3][ACEGEM: no window left.][ OK ]");
		v_clsvwk(vh);
		appl_exit();
		return 1;
	}
	Supexec(gk_timer_on);
	key_quiet = ticks();

	if (kernel_run(0) < 0)
		alert("[3][The Ace ran into an unknown|Z80 instruction.][ OK ]");

	/* let the keys go up (Control+Q), at most 3 seconds */
	if (gk_hooked) {
		long t0 = ticks();

		gk_hooked = 1;
		while (any_down() && ticks() - t0 < 600)
			evnt_timer(20);
		keys_manage(0);
		if (gk_hooked) {
			Supexec(gk_ikbd_off);
			gk_hooked = 0;
		}
	}
	Supexec(gk_timer_off);
	wind_close(win);
	wind_delete(win);
	v_clsvwk(vh);
	appl_exit();
	return 0;
}
