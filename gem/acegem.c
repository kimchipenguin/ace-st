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
 * Menus and shortcuts: what the user picks waits in "pending" until the
 * hook is out (all keys up), then runs from gem_frame(); so alerts, file
 * selectors and dialogs always get a keyboard TOS knows about.  The Ace
 * waits while another window (a dialog) is on top, or while it is paused.
 *
 * GPL v2 or later.
 */

#include <gem.h>
#include <cflib.h>
#include <mint/osbind.h>
#include <mint/cookie.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include "kernel.h"
#include "aesfix.h"
#include "acegem_rsc.h"
#include "kbpic.h"

#define RSC_FILE "ACEGEM.RSC"
#define INF_FILE "ACEGEM.INF"

#define ACE_W   256
#define ACE_H   192
#define MAXS    8                   /* largest scale */

#define SC_Q    0x10
#define SC_CTRL 0x1D
#define SC_LSH  0x2A
#define SC_ALT  0x38

/* actions that are no menu entry */
#define ACT_RAMRESET    1000        /* new RAM size: reset */
#define ACT_CLOSEW      1001        /* Control+W: close the dialog on top */

static short vh, win = -1;
static short kbw = -1;                      /* the keyboard window */
static short win_kind = NAME | CLOSER | MOVER | FULLER | SIZER;
static short pix_w = 1, pix_h = 1;          /* pixel shape, work_out[3/4] */
static GRECT desk, wwork, wfull_old, win_place;
static short fulled;

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
static short pending;                       /* menu item to do, 0 = none */
static short paused;
static long title_until;                    /* "saved" in the title until */
static char title_buf[64];

static OBJECT *menu, *dialog, *abouttree, *rampop;
extern OBJECT *cf_alert_box;                /* CF-Lib's alert tree */
static WDIALOG *wd, *wd_about;
static short dlg_x = -1, dlg_y = -1, abt_x = -1, abt_y = -1;
static char *key_text[5];                   /* the joystick key fields */
static short ram_new;                       /* RAM size for ACT_RAMRESET */

static char inf_path[300];
static char tape_path[300], snap_path[300]; /* file selector folders */

static long ticks(void)
{
	return ace_ticks200;
}

static char *rs_str(short i)
{
	char **p = NULL;

	rsrc_gaddr(R_FRSTR, i, &p);
	return p ? *p : "";
}

static short alert(short i)
{
	return do_walert(1, 1, rs_str(i), rs_str(FS_WINTITLE));
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

static void set_title(void)
{
#ifndef STATS
	char *t = paused ? rs_str(FS_PAUSED) : title_until ? title_buf : rs_str(FS_WINTITLE);

	if (win >= 0)
		wind_set_str(win, WF_NAME, t);
#endif
}

static void clamp_to_desk(GRECT *r)
{
	if (r->g_w > desk.g_w) r->g_w = desk.g_w;
	if (r->g_h > desk.g_h) r->g_h = desk.g_h;
	if (r->g_x + r->g_w > desk.g_x + desk.g_w) r->g_x = desk.g_x + desk.g_w - r->g_w;
	if (r->g_y + r->g_h > desk.g_y + desk.g_h) r->g_y = desk.g_y + desk.g_h - r->g_h;
	if (r->g_x < desk.g_x) r->g_x = desk.g_x;
	if (r->g_y < desk.g_y) r->g_y = desk.g_y;
}

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

/* at its place from ACEGEM.INF, else at the largest scale that fits on
   the desktop, centred */
static int open_window(void)
{
	GRECT b, w;
	short px, py;

	if (win_place.g_w > 0) {
		b = win_place;
		clamp_to_desk(&b);
	} else {
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
	}
	win = wind_create(win_kind, desk.g_x, desk.g_y, desk.g_w, desk.g_h);
	if (win < 0)
		return 0;
	set_title();
	wind_open(win, b.g_x, b.g_y, b.g_w, b.g_h);
	wind_get(win, WF_WORKXYWH, &wwork.g_x, &wwork.g_y, &wwork.g_w, &wwork.g_h);
	set_scale();
	return 1;
}

static void close_window(void)
{
	if (win < 0)
		return;
	if (fulled)
		win_place = wfull_old;
	else
		wind_get(win, WF_CURRXYWH, &win_place.g_x, &win_place.g_y,
		         &win_place.g_w, &win_place.g_h);
	wind_close(win);
	wind_delete(win);
	win = -1;
}

static int on_top(void)
{
	short top, d;

	if (win < 0)
		return 0;
	wind_get(0, WF_TOP, &top, &d, &d, &d);
	return top == win || (kbw >= 0 && top == kbw);   /* both get the keys */
}

/* ---------------------------------------------------------------- */
/* the keyboard window (as in sz81's Atari build)                    */
/* ---------------------------------------------------------------- */

/* EightyOne's picture of the Ace keyboard (gem/build/kbpic.h).  Every key
   the Ace sees down (typed, clicked or from the joystick) is lit, and stays
   so for a second after it went up: blue (red with 4 colours) on the key
   face, so the white lettering stays readable, inverted in monochrome.  A
   click holds a key for at least KB_CLICK; SHIFT and SYMBOL SHIFT stay
   down until the next key goes up.  On small screens the picture is
   halved: in height when the pixels are twice as high as wide (ST medium),
   in both directions when it is too wide for the desktop.  A dark pixel
   stays only when all of the halved pixels are dark, so the lettering
   stays white. */

#define KB_KEYS     40
#define KB_SHIFT    30
#define KB_SYMSHIFT 38
#define KB_LIT      200             /* ticks: 1 s */
#define KB_CLICK    16              /* ticks: 80 ms, the ROM must see it */
#define KB_KIND     (NAME | CLOSER | MOVER)

static short kb_x = -1, kb_y = -1;          /* place (ACEGEM.INF) */
static short kb_reopen;                     /* was open at the last quit */
static unsigned short *kb_pic;
static short kb_w, kb_h, kb_words;          /* the picture as drawn */
static short kb_r[KB_KEYS][4];              /* key faces in it */
static short kb_pen = -1;                   /* lit keys, -1 = invert */
static unsigned char kb_lit[KB_KEYS];
static long kb_lit_until[KB_KEYS];
static short kb_click = -1;                 /* key the mouse holds */
static long kb_click_until;
static unsigned char kb_latch[2];           /* SHIFT, SYMBOL SHIFT */
static short kb_mouse_prev;
static GRECT kb_work;

static int kb_any_lit(void)
{
	short i;

	if (kbw < 0)
		return 0;
	for (i = 0; i < KB_KEYS; i++)
		if (kb_lit[i])
			return 1;
	return 0;
}

static int kb_bit(short x, short y)
{
	return (kb_bits[y * KB_WORDS + (x >> 4)] >> (15 - (x & 15))) & 1;
}

/* the picture at the size for this screen */
static int kb_make(void)
{
	short dx = 1, dy = 1, x, y, i, j, k, wo[57];
	GRECT b;

	if (kb_pic)
		return 1;
	vq_extnd(vh, 1, wo);
	kb_pen = wo[4] == 1 ? -1 : wo[4] == 2 ? G_RED : G_BLUE;
	wind_calc(WC_BORDER, KB_KIND, 0, 0, KB_W, KB_H, &b.g_x, &b.g_y, &b.g_w, &b.g_h);
	if (b.g_w > desk.g_w)
		dx = dy = 2;
	if (pix_h >= 2 * pix_w)
		dy = 2;
	if (b.g_h - KB_H + KB_H / dy > desk.g_h)
		dy = 2;
	kb_w = KB_W / dx;
	kb_h = KB_H / dy;
	kb_words = (kb_w + 15) / 16;
	kb_pic = calloc((long)kb_words * kb_h, 2);
	if (!kb_pic)
		return 0;
	for (y = 0; y < kb_h; y++)
		for (x = 0; x < kb_w; x++) {
			short dark = 1;

			for (j = 0; j < dy; j++)
				for (i = 0; i < dx; i++)
					dark &= kb_bit(x * dx + i, y * dy + j);
			if (dark)
				kb_pic[y * kb_words + (x >> 4)] |= 0x8000 >> (x & 15);
		}
	for (k = 0; k < KB_KEYS; k++) {
		kb_r[k][0] = kb_face[k][0] / dx;
		kb_r[k][1] = kb_face[k][1] / dy;
		kb_r[k][2] = kb_face[k][2] / dx;
		kb_r[k][3] = kb_face[k][3] / dy;
	}
	return 1;
}

/* part r of the screen: the picture, the lit keys */
static void kb_paint(const GRECT *r)
{
	MFDB src, dst;
	short pxy[8], col[2], k;
	GRECT c;

	pxy[0] = r->g_x;
	pxy[1] = r->g_y;
	pxy[2] = r->g_x + r->g_w - 1;
	pxy[3] = r->g_y + r->g_h - 1;
	vs_clip(vh, 1, pxy);
	vswr_mode(vh, MD_REPLACE);
	vsf_interior(vh, FIS_SOLID);
	vsf_color(vh, G_WHITE);
	vr_recfl(vh, pxy);                  /* where the window is larger */

	memset(&dst, 0, sizeof dst);
	src.fd_addr = kb_pic;
	src.fd_w = kb_words * 16;
	src.fd_h = kb_h;
	src.fd_wdwidth = kb_words;
	src.fd_stand = 0;
	src.fd_nplanes = 1;
	src.fd_r1 = src.fd_r2 = src.fd_r3 = 0;
	c.g_x = kb_work.g_x;
	c.g_y = kb_work.g_y;
	c.g_w = kb_w;
	c.g_h = kb_h;
	if (!intersect(r, &c))
		return;
	pxy[0] = c.g_x - kb_work.g_x;
	pxy[1] = c.g_y - kb_work.g_y;
	pxy[2] = pxy[0] + c.g_w - 1;
	pxy[3] = pxy[1] + c.g_h - 1;
	pxy[4] = c.g_x;
	pxy[5] = c.g_y;
	pxy[6] = c.g_x + c.g_w - 1;
	pxy[7] = c.g_y + c.g_h - 1;
	col[0] = G_BLACK;
	col[1] = G_WHITE;
	vrt_cpyfm(vh, MD_REPLACE, pxy, &src, &dst, col);

	for (k = 0; k < KB_KEYS; k++) {
		GRECT kr;

		if (!kb_lit[k])
			continue;
		kr.g_x = kb_work.g_x + kb_r[k][0];
		kr.g_y = kb_work.g_y + kb_r[k][1];
		kr.g_w = kb_r[k][2];
		kr.g_h = kb_r[k][3];
		if (!intersect(&c, &kr))
			continue;
		pxy[4] = kr.g_x;
		pxy[5] = kr.g_y;
		pxy[6] = kr.g_x + kr.g_w - 1;
		pxy[7] = kr.g_y + kr.g_h - 1;
		if (kb_pen < 0) {
			vswr_mode(vh, MD_XOR);
			vsf_color(vh, G_BLACK);
			vr_recfl(vh, &pxy[4]);
			vswr_mode(vh, MD_REPLACE);
			continue;
		}
		pxy[0] = kr.g_x - kb_work.g_x;
		pxy[1] = kr.g_y - kb_work.g_y;
		pxy[2] = pxy[0] + kr.g_w - 1;
		pxy[3] = pxy[1] + kr.g_h - 1;
		col[0] = kb_pen;
		col[1] = G_WHITE;
		vrt_cpyfm(vh, MD_TRANS, pxy, &src, &dst, col);   /* the face only */
	}
}

static void kb_redraw(const GRECT *area)
{
	GRECT r, a = *area;

	if (kbw < 0 || !intersect(&desk, &a))
		return;
	wind_update(BEG_UPDATE);
	graf_mouse(M_OFF, NULL);
	wind_get(kbw, WF_FIRSTXYWH, &r.g_x, &r.g_y, &r.g_w, &r.g_h);
	while (r.g_w > 0 && r.g_h > 0) {
		if (intersect(&a, &r))
			kb_paint(&r);
		wind_get(kbw, WF_NEXTXYWH, &r.g_x, &r.g_y, &r.g_w, &r.g_h);
	}
	graf_mouse(M_ON, NULL);
	wind_update(END_UPDATE);
}

/* the matrix place of key k: rows 3-1 from the left half of the upper
   rows of the picture, 4-6 from the right half (bits from the outside
   in); the bottom row is SHIFT Z X C V B N M SYMBOL-SHIFT SPACE, and
   SYMBOL SHIFT is in row 0 */
static void kb_matrix(short k, short *row, short *mask)
{
	static const unsigned char bottom[10][2] = {
		{ 0, 0x01 }, { 0, 0x04 }, { 0, 0x08 }, { 0, 0x10 }, { 7, 0x10 },
		{ 7, 0x08 }, { 7, 0x04 }, { 7, 0x02 }, { 0, 0x02 }, { 7, 0x01 },
	};
	short r = k / 10, c = k % 10;

	if (r == 3) {
		*row = bottom[c][0];
		*mask = bottom[c][1];
		return;
	}
	*row = c < 5 ? 3 - r : 4 + r;
	*mask = 1 << (c < 5 ? c : 9 - c);
}

static void kb_send(short k, int down)
{
	short row, mask;

	kb_matrix(k, &row, &mask);
	kernel_matrix(row, mask, down);
}

/* the clicked key up, and SHIFT and SYMBOL SHIFT with it */
static void kb_release(void)
{
	short i;

	if (kb_click >= 0)
		kb_send(kb_click, 0);
	kb_click = -1;
	for (i = 0; i < 2; i++)
		if (kb_latch[i]) {
			kb_send(i ? KB_SYMSHIFT : KB_SHIFT, 0);
			kb_latch[i] = 0;
		}
}

static void kb_close(void)
{
	short d;

	if (kbw < 0)
		return;
	kb_release();
	wind_get(kbw, WF_CURRXYWH, &kb_x, &kb_y, &d, &d);
	wind_close(kbw);
	wind_delete(kbw);
	kbw = -1;
	menu_icheck(menu, MI_KEYBOARD, 0);
}

static void kb_open(void)
{
	GRECT b;
	short k;

	if (kbw >= 0) {
		wind_set(kbw, WF_TOP, 0, 0, 0, 0);
		return;
	}
	if (!kb_make()) {
		alert(AL_NOMEM);
		return;
	}
	wind_calc(WC_BORDER, KB_KIND, 0, 0, kb_w, kb_h, &b.g_x, &b.g_y, &b.g_w, &b.g_h);
	if (kb_x >= 0) {
		b.g_x = kb_x;
		b.g_y = kb_y;
	} else {                            /* centred at the bottom */
		b.g_x = desk.g_x + (desk.g_w - b.g_w) / 2;
		b.g_y = desk.g_y + desk.g_h - b.g_h;
	}
	clamp_to_desk(&b);
	kbw = wind_create(KB_KIND, desk.g_x, desk.g_y, desk.g_w, desk.g_h);
	if (kbw < 0) {
		alert(AL_NOWINDOW);
		return;
	}
	wind_set_str(kbw, WF_NAME, rs_str(FS_KBTITLE));
	for (k = 0; k < KB_KEYS; k++)
		kb_lit[k] = 0, kb_lit_until[k] = 0;
	kb_mouse_prev = 1;                  /* the menu click is no key */
	wind_open(kbw, b.g_x, b.g_y, b.g_w, b.g_h);
	wind_get(kbw, WF_WORKXYWH, &kb_work.g_x, &kb_work.g_y, &kb_work.g_w, &kb_work.g_h);
	menu_icheck(menu, MI_KEYBOARD, 1);
}

/* the key under a screen position, -1 = none */
static short kb_key_at(short mx, short my)
{
	short k, x = mx - kb_work.g_x, y = my - kb_work.g_y;

	for (k = 0; k < KB_KEYS; k++)
		if (x >= kb_r[k][0] && x < kb_r[k][0] + kb_r[k][2] &&
		    y >= kb_r[k][1] && y < kb_r[k][1] + kb_r[k][3])
			return k;
	return -1;
}

/* a new press of the left button at mx, my */
static int kb_press(short mx, short my)
{
	short k;

	if (kbw < 0 || paused || wind_find(mx, my) != kbw)
		return 0;
	k = kb_key_at(mx, my);
	if (k < 0)
		return 1;
	if (k == KB_SHIFT || k == KB_SYMSHIFT) {
		short i = k == KB_SYMSHIFT;

		kb_latch[i] = !kb_latch[i];
		kb_send(k, kb_latch[i]);
	} else if (kb_click < 0) {
		kb_send(k, 1);
		kb_click = k;
		kb_click_until = ticks() + KB_CLICK;
	}
	return 1;
}

/* every frame: the mouse (a press shorter than the time between two
   evnt_multi is seen here), the end of a click, the lit keys */
static void kb_poll(void)
{
	short mx, my, mb, ks, k;
	long now;

	if (kbw < 0)
		return;
	now = ticks();
	graf_mkstate(&mx, &my, &mb, &ks);
	if ((mb & 1) && !(kb_mouse_prev & 1))
		kb_press(mx, my);
	kb_mouse_prev = mb;
	if (kb_click >= 0 && !(mb & 1) && now >= kb_click_until)
		kb_release();
	for (k = 0; k < KB_KEYS; k++) {
		short row, mask, lit;

		kb_matrix(k, &row, &mask);
		if (!(ace_keyrows[row] & mask))
			kb_lit_until[k] = now + KB_LIT;
		lit = kb_lit_until[k] > now;
		if (lit != kb_lit[k]) {
			GRECT r;

			kb_lit[k] = lit;
			r.g_x = kb_work.g_x + kb_r[k][0];
			r.g_y = kb_work.g_y + kb_r[k][1];
			r.g_w = kb_r[k][2];
			r.g_h = kb_r[k][3];
			kb_redraw(&r);
		}
	}
}

/* the messages for the keyboard window; 1 = it was one */
static int kb_message(short *msg)
{
	GRECT r;

	if (kbw < 0 || msg[3] != kbw)
		return 0;
	r.g_x = msg[4];
	r.g_y = msg[5];
	r.g_w = msg[6];
	r.g_h = msg[7];
	switch (msg[0]) {
	case WM_REDRAW:
		kb_redraw(&r);
		break;
	case WM_TOPPED:
		wind_set(kbw, WF_TOP, 0, 0, 0, 0);
		break;
	case WM_CLOSED:
		kb_close();
		break;
	case WM_MOVED:
		clamp_to_desk(&r);
		wind_set(kbw, WF_CURRXYWH, r.g_x, r.g_y, r.g_w, r.g_h);
		wind_get(kbw, WF_WORKXYWH, &kb_work.g_x, &kb_work.g_y,
		         &kb_work.g_w, &kb_work.g_h);
		break;
	}
	return 1;
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

/* Control + the key with this character: a menu entry, done when the
   keys are up (the letter, not the key position, so it also works on
   AZERTY keyboards) */
static void ctrl_key(short ch)
{
	short item = 0;

	if (ch >= 0x01 && ch <= 0x1A)
		ch += 0x60;
	switch (ch | 0x20) {
	case 'q': want_quit = 1; return;
	case 'o': item = MI_TAPE; break;
	case 'l': item = MI_SNAP; break;
	case 't': item = MI_SHOT; break;
	case 'r': item = MI_RESET; break;
	case 'p': item = MI_PAUSE; break;
	case 's': item = MI_SETTINGS; break;
	case 'w': item = ACT_CLOSEW; break;
	case 'k': item = MI_KEYBOARD; break;
	}
	if (item && !pending)
		pending = item;
}

/* an AES key event (not hooked): the Ace sees it held for a while */
static void aes_key(short kstate, short kreturn)
{
	short sc = (kreturn >> 8) & 0x7F;
	long now = ticks();

	key_quiet = now;
	if (paused || !on_top() || sc == 0)
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

/* Control + key from the hook: its letter from the keyboard table */
static void ring_keys(void)
{
	static unsigned char rout;

	while (rout != gk_rin) {
		unsigned char sc = gk_ring[rout];
		_KEYTAB *kt = (_KEYTAB *)Keytbl((void *)-1, (void *)-1, (void *)-1);

		rout = (rout + 1) & 15;
		if (sc == SC_Q)
			want_quit = 1;
		else if (kt && sc < 128)
			ctrl_key((unsigned char)kt->unshift[sc]);
	}
}

/* the name of an Ace key (ST scancode) without blanks, as in ACE.INF */
static void key_name(short sc, char *out)
{
	const char *k = ace_keyname[sc & 127];
	short i;

	for (i = 0; i < 3; i++)
		if (k[i] && k[i] != ' ')
			*out++ = k[i];
	*out = 0;
}

/* the scancode of an Ace key name, -1 = none */
static short key_find(const char *t)
{
	char want[8], have[8];
	short i, n = 0;

	for (; *t && n < 7; t++)
		if (*t != ' ')
			want[n++] = (*t >= 'a' && *t <= 'z') ? *t - 32 : *t;
	want[n] = 0;
	if (!n)
		return -1;
	for (i = 0; i < 128; i++) {
		key_name(i, have);
		if (have[0] && strcmp(have, want) == 0)
			return i;
	}
	return -1;
}

/* ---------------------------------------------------------------- */
/* dialogs (CF-Lib window dialogs, as in the CHIP-8 emulator)        */
/* ---------------------------------------------------------------- */

/* The rows of a dialog get their places here, so that buttons are at
   least 17 pixels high and labels sit in the middle of their row, in every
   resolution: object 1 is the title, then come the group frames (their
   objects in the rows of the RSC, 1 = first), one below the other, and
   the other objects of the root (the buttons) in a row at the bottom. */
static int is_frame(OBJECT *t, short i)
{
	return (t[i].ob_type & 0xFF) == G_BUTTON && (t[i].ob_state & 0xFF00) == 0xFE00;
}

static short btn_h(void)
{
	return gl_hchar + 2 < 17 ? 17 : gl_hchar + 2;
}

static short row_h(void)
{
	return btn_h() + (gl_hchar >= 16 ? gl_hchar / 4 : 1);
}

/* the objects of frame i in their rows (ob_y holds the row number, 0 =
   first), and the height of the frame.  Rows with edit fields are taller:
   half a character between the borders of fields below each other. */
static void frame_rows(OBJECT *t, short i, short rows)
{
	short bh = btn_h(), rh = row_h();
	short ft = gl_hchar + gl_hchar / 4;     /* frame title */
	short o;

	for (o = t[i].ob_head; o != i && o >= 0; o = t[o].ob_next)
		if (t[o].ob_flags & OF_EDITABLE) {
			if (rh < gl_hchar + gl_hchar / 2 + 4)
				rh = gl_hchar + gl_hchar / 2 + 4;
			break;
		}
	for (o = t[i].ob_head; o != i && o >= 0; o = t[o].ob_next) {
		short type = t[o].ob_type & 0xFF;
		short h = type == G_BUTTON ? bh : gl_hchar;

		t[o].ob_height = h;
		t[o].ob_y = ft + t[o].ob_y * rh + (rh - h) / 2;
	}
	t[i].ob_height = ft + rows * rh + 2;
}

static void layout_dialog(OBJECT *t)
{
	short bh = btn_h();
	short gap = gl_hchar / 2;
	short y, i, o, row;

	/* the title: one character from every edge (CF-Lib hides it, it is
	   the name of the window) */
	t[1].ob_x = gl_wchar;
	t[1].ob_y = gl_hchar;
	t[1].ob_width = t[ROOT].ob_width - 2 * gl_wchar;
	t[1].ob_height = gl_hchar + 2;
	y = t[1].ob_y + t[1].ob_height + gl_hchar;

	for (i = t[ROOT].ob_head; i != ROOT && i >= 0; i = t[i].ob_next) {
		short rows = 0, shadow = 0;

		if (!is_frame(t, i))
			continue;
		for (o = t[i].ob_head; o != i && o >= 0; o = t[o].ob_next) {
			row = t[o].ob_y / gl_hchar - 1;         /* row from the RSC */
			if (row + 1 > rows)
				rows = row + 1;
			t[o].ob_y = row;                        /* for the next loop */
			if (t[o].ob_state & OS_SHADOWED)
				shadow = 1;
		}
		frame_rows(t, i, rows);
		t[i].ob_y = y;
		if (shadow)                             /* popups: room for the */
			t[i].ob_height += gl_hchar / 2;     /* shadow above the frame */
		y += t[i].ob_height + gap;
	}
	y += gap;
	for (i = t[ROOT].ob_head; i != ROOT && i >= 0; i = t[i].ob_next)
		if (i != 1 && !is_frame(t, i)) {
			t[i].ob_y = y;
			t[i].ob_height = bh;
		}
	t[ROOT].ob_height = y + bh + gl_hchar;
}

/* a dialog window, given by the place of its work area (what
   open_wdial() takes), inside the desktop; the title object is not shown */
static void clamp_dialog(OBJECT *t, short *x, short *y)
{
	const short k = NAME | MOVER | CLOSER;
	GRECT w, o;

	if (*x < 0 || *y < 0)
		return;
	w.g_x = *x;
	w.g_y = *y;
	w.g_w = t[ROOT].ob_width;
	w.g_h = t[ROOT].ob_height - (t[1].ob_y + t[1].ob_height);
	wind_calc(WC_BORDER, k, w.g_x, w.g_y, w.g_w, w.g_h, &o.g_x, &o.g_y, &o.g_w, &o.g_h);
	clamp_to_desk(&o);
	wind_calc(WC_WORK, k, o.g_x, o.g_y, o.g_w, o.g_h, &w.g_x, &w.g_y, &w.g_w, &w.g_h);
	*x = w.g_x;
	*y = w.g_y;
}

/* a non-modal dialog on top? */
static int wdial_top(WDIALOG *d)
{
	short t, x;

	if (!d || d->mode != WD_OPEN)
		return 0;
	wind_get(0, WF_TOP, &t, &x, &x, &x);
	return t == d->win_handle;
}

/* open a non-modal dialog: again where it was, at the place from
   ACEGEM.INF, or centred */
static WDIALOG *open_dialog(WDIALOG **d, OBJECT *tree, short edit,
                            WDIAL_XCB exit_cb, short x, short y)
{
	if (!*d) {
		*d = create_wdial(tree, NULL, edit, WOCB_NULL, exit_cb);
		if (!*d)
			return NULL;
	}
	if ((*d)->win_handle > 0 || x < 0 || y < 0)
		open_wdial(*d, -1, -1);
	else {
		clamp_dialog(tree, &x, &y);
		open_wdial(*d, x, y);
	}
	return *d;
}

/* the entry of a popup that its box shows */
static short popup_choice(short box, OBJECT *pop)
{
	char s[32], t[32];
	short i;

	get_string(dialog, box, s);
	for (i = pop[ROOT].ob_head; i != ROOT && i >= 0; i = pop[i].ob_next) {
		get_string(pop, i, t);
		if (strcmp(s, t) == 0)
			return i - pop[ROOT].ob_head;
	}
	return 0;
}

static void popup_show(short box, OBJECT *pop, short entry)
{
	char s[32];

	get_string(pop, pop[ROOT].ob_head + entry, s);
	set_string(dialog, box, s);
}

/* ---------------------------------------------------------------- */
/* Settings: RAM size (with a reset) and the joystick keys           */
/* ---------------------------------------------------------------- */

static const short key_obj[5] = { D_KUP, D_KDOWN, D_KLEFT, D_KRIGHT, D_KFIRE };

static short ram_index(void)
{
	return (ace_ram_last >> 14) & 3;
}

static void settings_fill(void)
{
	short i;

	popup_show(D_RAM, rampop, ram_index());
	for (i = 0; i < 5; i++)
		key_name(ace_joy_map[i], key_text[i]);
}

/* the key fields into the joystick map; a name that is no Ace key keeps
   the key it had */
static void settings_read(void)
{
	short i, sc;

	if (!wd || wd->mode != WD_OPEN)
		return;
	for (i = 0; i < 5; i++) {
		sc = key_find(key_text[i]);
		if (sc >= 0)
			ace_joy_map[i] = sc;
	}
}

static int settings_exit(WDIALOG *d, short obj)
{
	short old, n;

	(void)d;
	obj &= 0x7FFF;                      /* bit 15: double click */
	switch (obj) {
	case D_RAM:
	case D_RAMLBL:
		old = ram_index();
		handle_popup(dialog, D_RAM, rampop, ROOT, obj == D_RAM ? POP_OPEN : POP_CYCLE);
		n = popup_choice(D_RAM, rampop);
		if (n != old) {
			if (do_walert(1, 2, rs_str(AL_RAM), rs_str(FS_WINTITLE)) == 1) {
				ram_new = n;
				pending = ACT_RAMRESET;
			} else {
				popup_show(D_RAM, rampop, old);
				redraw_wdobj(wd, D_RAM);
			}
		}
		return 0;
	case D_CLOSE:
	case WD_CLOSER:
		settings_read();
		if (wd->win_handle > 0) {
			dlg_x = wd->work.g_x;
			dlg_y = wd->work.g_y;
		}
		return 1;
	}
	return 0;
}

static void settings(void)
{
	settings_fill();
	open_dialog(&wd, dialog, D_KUP, settings_exit, dlg_x, dlg_y);
}

static int about_exit(WDIALOG *d, short obj)
{
	(void)obj;
	if (d->win_handle > 0) {
		abt_x = d->work.g_x;
		abt_y = d->work.g_y;
	}
	return 1;                           /* OK, Undo or the closer: close */
}

static void about(void)
{
	open_dialog(&wd_about, abouttree, 0, about_exit, abt_x, abt_y);
}

/* ---------------------------------------------------------------- */
/* files                                                             */
/* ---------------------------------------------------------------- */

/* the folder the program was started from (where ACEGEM.INF is), with a
   backslash at the end */
static void app_folder(char *out)
{
	char *p;

	strcpy(out, inf_path);
	p = strrchr(out, '\\');
	if (p)
		p[1] = 0;
}

/* the file selector; path keeps its folder and mask */
static int choose(char *path, char *name, short title, const char *mask, char *full)
{
	short button = 0, ok;
	char *p;

	if (!path[0]) {
		app_folder(path);
		strcat(path, mask);
	}
	if (_AESversion >= 0x140)
		ok = fsel_exinput(path, name, &button, rs_str(title));
	else
		ok = fsel_input(path, name, &button);
	if (!ok || !button || name[0] == 0)
		return 0;
	strcpy(full, path);
	p = strrchr(full, '\\');
	if (p)
		p[1] = 0;
	else
		full[0] = 0;
	strcat(full, name);
	return 1;
}

/* File > Open tape: the tape for the next LOAD / SAVE (a new name makes
   a new, empty tape, as in ACE.PRG) */
static void open_tape(void)
{
	static char name[16];
	char full[300];

	if (!choose(tape_path, name, FS_FSEL_TAPE, "*.*", full))
		return;
	if (strlen(full) >= 169)
		return;
	kernel_tape_close();
	strcpy(ace_tapename, full);
}

/* File > Load snapshot: 1 = read, the kernel starts it */
static int load_snap(void)
{
	static char name[16];
	char full[300];
	int r;

	if (!choose(snap_path, name, FS_FSEL_SNAP, "*.ACE", full))
		return 0;
	graf_mouse(BUSYBEE, NULL);
	r = ace_snap_read(full);
	graf_mouse(ARROW, NULL);
	if (r == 0)
		return 1;
	alert(r == -2 ? AL_NOSNAP : r == -3 ? AL_NOMEM : AL_NOFILE);
	return 0;
}

/* screenshot: the Ace screen as a 1-bit PNG, 256 x 192, in SCNSHT\ next
   to the program (SHOT0001.PNG, ...) */
#define SHOT_ROW (1 + ACE_W / 8)            /* filter byte + pixels */

static void be32(unsigned char *p, unsigned long v)
{
	p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

static int png_chunk(short fh, const char *type, const unsigned char *data,
                     unsigned long len)
{
	unsigned char head[8], crc[4];
	unsigned long sum;

	be32(head, len);
	memcpy(head + 4, type, 4);
	sum = crc32(0L, head + 4, 4);
	if (len)
		sum = crc32(sum, data, len);
	be32(crc, sum);
	return Fwrite(fh, 8, head) == 8 &&
	       (!len || Fwrite(fh, len, data) == (long)len) &&
	       Fwrite(fh, 4, crc) == 4;
}

static int shot_write(const char *name)
{
	static const unsigned char sig[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
	static const unsigned char plte[6] = { 0, 0, 0, 255, 255, 255 };
	static unsigned char raw[ACE_H * SHOT_ROW], packed[ACE_H * SHOT_ROW + 1024];
	const unsigned char *vram = ace_mem + 0x2400, *cram = ace_mem + 0x2C00;
	unsigned char ihdr[13], *r = raw;
	uLongf plen = sizeof packed;
	short y, x;
	long fh;
	int ok;

	for (y = 0; y < ACE_H; y++) {
		*r++ = 0;                           /* no filter */
		for (x = 0; x < 32; x++) {
			unsigned char c = vram[(y >> 3) * 32 + x];

			*r++ = cram[(c & 0x7F) * 8 + (y & 7)] ^ ((c & 0x80) ? 0xFF : 0);
		}
	}
	if (compress2(packed, &plen, raw, sizeof raw, Z_BEST_COMPRESSION) != Z_OK)
		return 0;
	be32(ihdr, ACE_W);
	be32(ihdr + 4, ACE_H);
	ihdr[8] = 1;                            /* 1 bit a pixel */
	ihdr[9] = 3;                            /* with a palette */
	ihdr[10] = ihdr[11] = ihdr[12] = 0;

	fh = Fcreate(name, 0);
	if (fh < 0)
		return 0;
	ok = Fwrite((short)fh, 8, sig) == 8 &&
	     png_chunk((short)fh, "IHDR", ihdr, 13) &&
	     png_chunk((short)fh, "PLTE", plte, 6) &&
	     png_chunk((short)fh, "IDAT", packed, plen) &&
	     png_chunk((short)fh, "IEND", NULL, 0);
	if (Fclose((short)fh) < 0)
		ok = 0;
	if (!ok)
		Fdelete(name);
	return ok;
}

static void screenshot(void)
{
	char path[300], *p;
	_DTA dta, *old;
	short l, num = 0, v;

	app_folder(path);
	strcat(path, rs_str(FS_SHOTDIR));
	Dcreate(path);                      /* fails if it is there: fine */
	strcat(path, "\\");
	l = strlen(path);

	/* the next number after the highest SHOTnnnn.PNG */
	strcpy(path + l, "SHOT*.PNG");
	old = Fgetdta();
	Fsetdta(&dta);
	if (Fsfirst(path, 0) == 0)
		do {
			p = dta.dta_name;
			if ((p[0] == 'S' || p[0] == 's') && p[4] >= '0' && p[4] <= '9') {
				v = atoi(p + 4);
				if (v > num)
					num = v;
			}
		} while (Fsnext() == 0);
	Fsetdta(old);
	if (num >= 9999) {
		alert(AL_SHOT);
		return;
	}
	sprintf(path + l, "SHOT%04d.PNG", num + 1);
	graf_mouse(BUSYBEE, NULL);
	v = shot_write(path);
	graf_mouse(ARROW, NULL);
	if (!v) {
		alert(AL_SHOT);
		return;
	}
	/* the name in the title for 3 seconds */
	snprintf(title_buf, sizeof title_buf, "%s%s ", rs_str(FS_SHOTSAVED), path + l);
	title_until = ticks() + 600;
	set_title();
}

/* ACEGEM.INF: RAM and JOYSTICK as in ACE.INF, plus the places of the
   windows and the folders of the file selectors */
static void inf_load(void)
{
	FILE *f = fopen(inf_path, "r");
	char line[320], k[5][8];
	int a, b, c, d;
	short i;

	if (!f)
		return;
	while (fgets(line, sizeof line, f)) {
		char *nl = strpbrk(line, "\r\n");

		if (nl)
			*nl = 0;
		if (sscanf(line, "RAM %dK", &a) == 1) {
			for (i = 0; i < 4; i++)
				if (a == 3 + 16 * i)
					ace_ram_last = (i << 14) | 0x3FFF;
		} else if (sscanf(line, "JOYSTICK %7s %7s %7s %7s %7s",
		                  k[0], k[1], k[2], k[3], k[4]) == 5) {
			for (i = 0; i < 5; i++) {
				short sc = key_find(k[i]);

				if (sc >= 0)
					ace_joy_map[i] = sc;
			}
		} else if (sscanf(line, "WINDOW %d %d %d %d", &a, &b, &c, &d) == 4) {
			win_place.g_x = a; win_place.g_y = b;
			win_place.g_w = c; win_place.g_h = d;
		} else if (sscanf(line, "SETTINGS %d %d", &a, &b) == 2) {
			dlg_x = a; dlg_y = b;
		} else if (sscanf(line, "KEYBOARD %d %d %d", &a, &b, &c) == 3) {
			kb_x = a; kb_y = b; kb_reopen = c;
		} else if (sscanf(line, "ABOUT %d %d", &a, &b) == 2) {
			abt_x = a; abt_y = b;
		} else if (strncmp(line, "TAPES ", 6) == 0)
			snprintf(tape_path, sizeof tape_path, "%.255s", line + 6);
		else if (strncmp(line, "SNAPSHOTS ", 10) == 0)
			snprintf(snap_path, sizeof snap_path, "%.255s", line + 10);
	}
	fclose(f);
}

static void inf_save(void)
{
	FILE *f = fopen(inf_path, "w");
	char n[5][8];
	short i;

	if (!f)
		return;
	for (i = 0; i < 5; i++)
		key_name(ace_joy_map[i], n[i]);
	fprintf(f, "RAM %dK\n", 3 + 16 * ram_index());
	fprintf(f, "JOYSTICK %s %s %s %s %s\n", n[0], n[1], n[2], n[3], n[4]);
	if (win_place.g_w > 0)
		fprintf(f, "WINDOW %d %d %d %d\n", win_place.g_x, win_place.g_y,
		        win_place.g_w, win_place.g_h);
	if (dlg_x >= 0)
		fprintf(f, "SETTINGS %d %d\n", dlg_x, dlg_y);
	if (abt_x >= 0)
		fprintf(f, "ABOUT %d %d\n", abt_x, abt_y);
	if (kb_x >= 0)
		fprintf(f, "KEYBOARD %d %d %d\n", kb_x, kb_y, kb_reopen);
	if (tape_path[0])
		fprintf(f, "TAPES %s\n", tape_path);
	if (snap_path[0])
		fprintf(f, "SNAPSHOTS %s\n", snap_path);
	fclose(f);
}

/* ---------------------------------------------------------------- */
/* menu actions                                                      */
/* ---------------------------------------------------------------- */

/* one action, with the hook out; returns what the kernel is to do */
static int do_action(short item)
{
	switch (item) {
	case MI_ABOUT:
		about();
		break;
	case MI_TAPE:
		open_tape();
		break;
	case MI_SNAP:
		if (load_snap())
			return GF_SNAP;
		break;
	case MI_SHOT:
		screenshot();
		break;
	case MI_QUIT:
		want_quit = 1;
		break;
	case MI_RESET:
		return GF_RESET;
	case MI_PAUSE:
		paused = !paused;
		menu_icheck(menu, MI_PAUSE, paused);
		set_title();
		break;
	case MI_SETTINGS:
		settings();
		break;
	case MI_KEYBOARD:
		if (kbw >= 0)
			kb_close();
		else
			kb_open();
		break;
	case ACT_RAMRESET:
		ace_ram_last = (ram_new << 14) | 0x3FFF;
		return GF_RESET;
	case ACT_CLOSEW:
		if (wdial_top(wd)) {
			settings_exit(wd, D_CLOSE);
			close_wdial(wd);
		} else if (wdial_top(wd_about)) {
			about_exit(wd_about, A_OK);
			close_wdial(wd_about);
		} else if (kbw >= 0 && on_top() && !wdial_top(wd)) {
			short top, d;

			wind_get(0, WF_TOP, &top, &d, &d, &d);
			if (top == kbw)
				kb_close();
		}
		break;
	}
	return GF_GO;
}

/* ---------------------------------------------------------------- */
/* events                                                            */
/* ---------------------------------------------------------------- */

static void message(short *msg)
{
	GRECT r;

	switch (msg[0]) {
	case MN_SELECTED:
		if (!pending)
			pending = msg[4];
		menu_tnormal(menu, msg[3], 1);
		return;
	case AP_TERM:
		want_quit = 1;
		return;
	}
	if (message_wdial(msg) || kb_message(msg))
		return;
	if (msg[3] != win)
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
		want_quit = 1;
		break;
	case WM_MOVED:
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

/* while a CF-Lib alert is open, it passes on the messages for our
   windows: draw them again and follow moves */
static void mdial_messages(short *msg)
{
	switch (msg[0]) {
	case WM_REDRAW:
	case WM_MOVED:
	case WM_SIZED:
		message(msg);
		break;
	}
}

/* one evnt_multi; wait (the Ace waits) blocks, but looks every 20 ms
   while the hook is still going out */
static void events(int wait)
{
	short msg[8], mx, my, mb, ks, kr, br, ev;
	short timer = !wait || gk_hooked || kb_any_lit() || kb_click >= 0;
	short button = wait || kbw >= 0;

	ev = evnt_multi(MU_MESAG | MU_KEYBD | (button ? MU_BUTTON : 0) | (timer ? MU_TIMER : 0),
	                0x102, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	                msg, wait ? 20 : 0, &mx, &my, &mb, &ks, &kr, &br);
	if (ev & MU_MESAG)
		message(msg);
	if (ev & MU_KEYBD) {
		short ch = kr & 0xFF, sc = (kr >> 8) & 0xFF;
		/* Control+letter gives the letter - 0x40 (some AES leave K_CTRL out) */
		int ctrl = (ks & K_CTRL) || (ch >= 0x01 && ch <= 0x1A && sc != 0x1C &&
		           sc != 0x72 && sc != 0x0E && sc != 0x0F);

		if (ctrl) {
			_KEYTAB *kt = (_KEYTAB *)Keytbl((void *)-1, (void *)-1, (void *)-1);

			key_quiet = ticks();
			if (!ch && kt && sc < 128)
				ch = (unsigned char)kt->unshift[sc];
			ctrl_key(ch);
		} else if (!key_wdial(kr, ks))
			aes_key(ks, kr);
	}
	if ((ev & MU_BUTTON) && (mb & 1)) {
		if (kb_press(mx, my))
			kb_mouse_prev = 1;          /* not again from kb_poll() */
		else if (wait)
			click_wdial(br, mx, my, ks, mb);
	}
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
	kb_poll();
	if (title_until && ticks() >= title_until) {
		title_until = 0;
		set_title();
	}
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
	/* a menu entry or shortcut: once the keys are up and the hook is out */
	if (pending && !want_quit) {
		keys_manage(0);
		if (!gk_hooked) {
			short item = pending;
			int r;

			pending = 0;
			r = do_action(item);
			if (r != GF_GO)
				return r;
		}
	}
	/* an evnt_multi costs some 5 ms on an 8 MHz ST: every third frame */
	if (++ev_div >= 3 || want_quit) {
		short waited = 0;

		ev_div = 0;
		events(0);
		/* paused, or not on top (a dialog, another program): the Ace waits */
		while (!want_quit && !pending && (paused || !on_top())) {
			keys_manage(0);
			events(1);
			kb_poll();
			waited = 1;
		}
		if (waited)
			settings_read();            /* key fields typed in meanwhile */
		if (!want_quit && !pending)
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
	char path[300];
	long fh, n;

	app_folder(path);
	strcat(path, "ACE.ROM");
	fh = Fopen(path, 0);
	if (fh < 0)
		fh = Fopen("ACE.ROM", 0);
	if (fh < 0)
		return 0;
	n = Fread((short)fh, 8192, ace_mem);
	Fclose((short)fh);
	return n == 8192;
}

/* ACEGEM.INF lives in the folder the program was started from */
static void find_inf(void)
{
	short drv = Dgetdrv();

	inf_path[0] = 'A' + drv;
	inf_path[1] = ':';
	Dgetpath(inf_path + 2, drv + 1);
	if (inf_path[strlen(inf_path) - 1] != '\\')
		strcat(inf_path, "\\");
	strcat(inf_path, INF_FILE);
}

/* MyAES: its ID from appl_getinfo_str(AES_VERSION), else an application
   of that name (as in the CHIP-8 emulator) */
static int is_myaes(void)
{
	static char id[12], name[256], info[256], more[256];
	short i;

	memset(id, 0, sizeof id);
	if (_AESversion >= 0x400 || appl_find("?AGI    ") >= 0) {
		if (appl_getinfo_str(AES_VERSION, id, name, info, more)) {
			for (i = 0; i < 5; i++)
				if (id[i] >= 'a' && id[i] <= 'z')
					id[i] -= 'a' - 'A';
			if (memcmp(id, "MYAES", 5) == 0)
				return 1;
		}
	}
	return appl_find("MYAES   ") >= 0;
}

static void quit_gem(void)
{
	v_clsvwk(vh);
	exit_gem();
}

int main(void)
{
	short work_in[11], work_out[57], d, i;
	long rate, v;
	int r;

	find_inf();
	init_app(RSC_FILE);                 /* stops with an alert without it */
	if (gl_apid < 0)
		return 1;
	if (Getcookie(0x5F43465FL, &v) == C_FOUND) {     /* _CF_: ColdFire */
		alert(AL_COLDFIRE);
		exit_gem();
		return 1;
	}
	if (is_myaes())
		cf_use_all_userdefs(1);
	rsrc_gaddr(R_TREE, MENU, &menu);
	rsrc_gaddr(R_TREE, SETDIAL, &dialog);
	rsrc_gaddr(R_TREE, ABOUT, &abouttree);
	rsrc_gaddr(R_TREE, RAMPOP, &rampop);
	if (_AESnumapps != 1)
		menu_register(gl_apid, rs_str(FS_APPNAME));
	if (_AESversion >= 0x400)
		shel_write(SWM_NEWMSG, NM_APTERM, 0, NULL, NULL);
	graf_mouse(ARROW, NULL);

	vh = graf_handle(&d, &d, &d, &d);
	for (i = 0; i < 10; i++)
		work_in[i] = 1;
	work_in[10] = 2;
	v_opnvwk(work_in, &vh, work_out);
	if (vh <= 0) {
		alert(AL_NOVDI);
		exit_gem();
		return 1;
	}
	pix_w = work_out[3] > 0 ? work_out[3] : 1;
	pix_h = work_out[4] > 0 ? work_out[4] : 1;
	if (work_out[0] + 1 < ACE_W || work_out[1] + 1 < ACE_H / 2) {
		alert(AL_SMALL);
		quit_gem();
		return 1;
	}
	wind_get(0, WF_WORKXYWH, &desk.g_x, &desk.g_y, &desk.g_w, &desk.g_h);

	for (i = 0; i < 5; i++)
		key_text[i] = dialog[key_obj[i]].ob_spec.tedinfo->te_ptext;
	layout_dialog(dialog);
	layout_dialog(abouttree);
	fix_dial(dialog);                   /* MagiC objects, emulated if needed */
	fix_dial(abouttree);
	fix_popup(rampop, 1);
	aesfix_userdefs(dialog);            /* draw them on our own stack */
	aesfix_userdefs(abouttree);
	aesfix_userdefs(rampop);
	aesfix_userdefs(cf_alert_box);
	set_mdial_wincb(mdial_messages);

	if (!load_rom()) {
		alert(AL_NOROM);
		quit_gem();
		return 1;
	}
	ace_ram_last = 0xFFFF;                      /* 51K */
	inf_load();
	kernel_init();
	patch_flags();

	has_acia = acia_machine();
	rate = Kbrate(-1, -1);
	hold_first = ((rate >> 8) & 0xFF) * 4 + 10; /* Kbrate counts 20 ms */
	hold_next = (rate & 0xFF) * 4 + 10;

	create_menu(menu);
	aesfix_userdefs(menu);
	if (!open_window()) {
		alert(AL_NOWINDOW);
		delete_menu();
		quit_gem();
		return 1;
	}
	if (kb_reopen)
		kb_open();
	Supexec(gk_timer_on);
	key_quiet = ticks();

	r = kernel_run(0);

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
	if (r < 0)
		alert(AL_BADOP);

	settings_read();
	if (wd && wd->mode == WD_OPEN && wd->win_handle > 0) {
		dlg_x = wd->work.g_x;
		dlg_y = wd->work.g_y;
	}
	if (wd_about && wd_about->mode == WD_OPEN && wd_about->win_handle > 0) {
		abt_x = wd_about->work.g_x;
		abt_y = wd_about->work.g_y;
	}
	kb_reopen = kbw >= 0;
	kb_close();
	close_window();
	inf_save();
	if (wd)
		delete_wdial(wd);
	if (wd_about)
		delete_wdial(wd_about);
	delete_menu();
	quit_gem();
	return 0;
}
