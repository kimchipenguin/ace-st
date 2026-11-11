/* acetype: a headless Jupiter Ace that types text files into the ROM.
 *
 * usage: acetype <ace.rom> <tape out> <file>...
 *
 * Runs the Ace ROM on xAce's Z80 core (z80ops.c, cbops.c, edops.c, GPL v2+)
 * with 19K of RAM, types each file key by key (3 frames down, 2 up; Enter is
 * followed by a pause until the ROM waits for a key again, in its loop
 * at 0594) and writes what the
 * ROM saves (SAVE, BSAVE) to <tape out> in xAce's block format (.TAP).
 *
 * A line that leaves text in the input line after Enter (a compile error)
 * stops the run with a screen dump and exit code 1.  Lines starting with
 * '#' are commands, not typed:
 *   #screen        print the Ace screen
 *   #wait n        run n frames (50 Hz)
 *   #key c n m     hold key c for n frames, then run m frames (c: a letter or
 *                  digit, "space" or "enter")
 *   #ram n         RAM size in K (3, 19, 35, 51), only before the first line
 *   #noerr         don't treat text left in the input line as an error
 *   #snap file     write a .ace snapshot (Ace32/EightyOne format) of the
 *                  running Ace
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "z80.h"

unsigned char mem[65536];
unsigned char *memptr[8];
int memattr[8] = {0, 1, 1, 1, 1, 1, 1, 1};
volatile int interrupted;
int reset_ace;
unsigned long tstates, tsmax = 0xffffffffUL;
static unsigned char partable[256];
#define parity(a) (partable[a])

/* xAce keyboard.c: char, row, mask, row 2, mask 2 (row 2 = -1: none).
   Row r is read with bit r of the port's high byte low. */
static const struct { int ch, r1, m1, r2, m2; } keytab[] = {
#include "acekeys.inc"
};
static unsigned char kp[8];

static void keys_clear(void) { memset(kp, 0xff, sizeof kp); }
static int keys_set(int ch)
{
  unsigned k;
  for (k = 0; k < sizeof keytab / sizeof keytab[0]; k++)
    if (keytab[k].ch == ch) {
      kp[keytab[k].r1] &= keytab[k].m1;
      if (keytab[k].r2 >= 0) kp[keytab[k].r2] &= keytab[k].m2;
      return 0;
    }
  return -1;
}

unsigned int in(int h, int l)
{
  int r, v = 0xff;
  (void)l;
  for (r = 0; r < 8; r++)
    if (!(h & 1 << r)) v &= kp[r];
  return v;
}
unsigned int out(int h, int l, int a) { (void)h; (void)l; (void)a; return 0; }
void do_interrupt(void) {}
void fix_tstates(void) { tstates = 0; }

static FILE *tout;
static int saves;
void tape_load_p(char *m, int dest) { (void)m; (void)dest; }
void tape_save_p(char *m, int size)
{
  int k, x = 0;
  for (k = 0; k < size; k++) x ^= (unsigned char)m[k];
  fputc((size + 1) & 255, tout);
  fputc((size + 1) >> 8, tout);
  fwrite(m, 1, size, tout);
  fputc(x, tout);
  saves++;
}

static void screen(void)
{
  int y, x;
  printf("+--------------------------------+\n");
  for (y = 0; y < 24; y++) {
    putchar('|');
    for (x = 0; x < 32; x++) {
      int c = mem[0x2400 + 32 * y + x] & 127;
      putchar(c >= 32 && c < 127 ? c : c == 0 ? ' ' : '0' + (c < 10 ? c : 9));
    }
    printf("|\n");
  }
  printf("+--------------------------------+\n");
}

/* the bottom screen line holds the input line: empty = only blanks and
   the (inverse) cursor */
static int input_empty(void)
{
  int x;
  for (x = 0; x < 32; x++)
  {
    int ch = mem[0x2400 + 32 * 23 + x];
    if (ch != ' ' && ch != 0 && ch < 128) return 0;   /* cursor is inverse */
  }
  return 1;
}

/* Z80 state */
static unsigned char a, f, b, c, d, e, h, l;
static unsigned char r, a1, f1, b1, c1, d1, e1, h1, l1, i_, iff1, iff2, im;
static unsigned short pc, ix, iy, sp;
static unsigned int radjust;
static unsigned char ixoriy, new_ixoriy, intsample, op;
static unsigned long frames;
static unsigned short framepc;      /* PC at the last frame end */

#define FRAME_T 65000UL               /* 3.25 MHz / 50 */
static void run(int nframes)
{
  unsigned long until = frames + nframes;
  while (frames < until) {
    unsigned long t0 = tstates;
    while (tstates - t0 < FRAME_T) {
      ixoriy = new_ixoriy;
      new_ixoriy = 0;
      intsample = 1;
      op = fetch(pc);
      pc++;
      radjust++;
#define i i_
      switch (op) {
#include "z80ops.c"
      }
#undef i
    }
    frames++;
    /* interrupt at the frame end; wait (HALT, DI) until it is taken */
    while (!iff1 || !intsample) {
      ixoriy = new_ixoriy;
      new_ixoriy = 0;
      intsample = 1;
      op = fetch(pc);
      pc++;
      radjust++;
#define i i_
      switch (op) {
#include "z80ops.c"
      }
#undef i
    }
    framepc = pc;
    if (mem[pc] == 0x76) pc++;          /* leave HALT */
    push2(pc);
    pc = 0x38;
  }
}

/* .ace snapshot as EightyOne writes it: memory 2000-RAMTOP, RLE (ED n b),
   with a header in the 2000-23FF mirror of the video RAM */
static void snap(const char *name, int ramtop)
{
  static unsigned char m[65536];
  unsigned short rr[12];
  int k, ad;
  FILE *fp = fopen(name, "wb");
  if (!fp) { perror(name); exit(2); }
  memcpy(m, mem, sizeof m);
  memset(m + 0x2000, 0, 0x200);
  m[0x2000] = 0x01; m[0x2001] = 0x80;
  m[0x2081] = (ramtop + 1) >> 8;
  m[0x228c] = m[0x2290] = 3;            /* as EightyOne (it writes these at 028x) */
  m[0x2294] = m[0x2295] = 0xfd;
  m[0x2298] = 1;
  rr[0] = a << 8 | f;  rr[1] = b << 8 | c;   rr[2] = d << 8 | e;  rr[3] = h << 8 | l;
  rr[4] = ix;          rr[5] = iy;           rr[6] = sp;          rr[7] = pc;
  rr[8] = a1 << 8 | f1; rr[9] = b1 << 8 | c1; rr[10] = d1 << 8 | e1; rr[11] = h1 << 8 | l1;
  for (k = 0; k < 12; k++) { m[0x2100 + 4 * k] = rr[k] & 255; m[0x2101 + 4 * k] = rr[k] >> 8; }
  m[0x2130] = im; m[0x2134] = iff1; m[0x2138] = iff2; m[0x213c] = i_;
  m[0x2140] = (r & 0x80) | (radjust & 0x7f);
  m[0x2144] = 0x80;
  for (ad = 0x2000; ad <= ramtop; ) {
    int ch = m[ad], n = 1;
    while (ad + n <= ramtop && m[ad + n] == ch && n < 240) n++;
    if (n > 3 || ch == 0xed) { fputc(0xed, fp); fputc(n, fp); }
    else n = 1;
    fputc(ch, fp);
    ad += n;
  }
  fputc(0xed, fp); fputc(0, fp);
  fclose(fp);
}

static void typekey(int ch, int down, int up)
{
  keys_clear();
  if (keys_set(ch)) { fprintf(stderr, "no Ace key for '%c' (%d)\n", ch, ch); exit(2); }
  run(down);
  keys_clear();
  run(up);
}

int main(int argc, char **argv)
{
  FILE *fp;
  int k, noerr = 0, started = 0, ramk = 19;
  char line[512];

  if (argc < 4) {
    fprintf(stderr, "usage: acetype <ace.rom> <tape out> <file>...\n");
    return 2;
  }
  for (k = 0; k < 256; k++) {
    int v = k, p = 0;
    while (v) { p ^= v & 1; v >>= 1; }
    partable[k] = p ? 0 : 4;
  }
  for (k = 0; k < 8; k++) memptr[k] = mem + 0x2000 * k;
  memset(mem, 0xff, sizeof mem);
  fp = fopen(argv[1], "rb");
  if (!fp || fread(mem, 1, 8192, fp) != 8192) { perror(argv[1]); return 2; }
  fclose(fp);
  mem[0x18a7] = 0xed; mem[0x18a8] = 0xfc; mem[0x18a9] = 0xc9;
  mem[0x1820] = 0xed; mem[0x1821] = 0xfd; mem[0x1822] = 0xc9;
  tout = fopen(argv[2], "wb");
  if (!tout) { perror(argv[2]); return 2; }
  keys_clear();
  a=f=b=c=d=e=h=l=a1=f1=b1=c1=d1=e1=h1=l1=i_=r=iff1=iff2=im=0;
  ixoriy = new_ixoriy = 0;
  ix = iy = sp = pc = 0;
  radjust = 0;

  for (k = 3; k < argc; k++) {
    int ln = 0;
    fp = fopen(argv[k], "r");
    if (!fp) { perror(argv[k]); return 2; }
    while (fgets(line, sizeof line, fp)) {
      char *p, w[256];
      int n1, n2;
      ln++;
      line[strcspn(line, "\r\n")] = 0;
      if (sscanf(line, "#ram %d", &n1) == 1) { ramk = n1; continue; }
      if (!strcmp(line, "#noerr")) { noerr = 1; continue; }
      if (!started) {                   /* RAM above the size reads FF */
        int top = ramk == 3 ? 0x4000 : ramk == 19 ? 0x8000 : ramk == 35 ? 0xc000 : 0x10000;
        for (n1 = top >> 13; n1 < 8; n1++) memattr[n1] = 0;
        run(150);                       /* boot */
        started = 1;
      }
      if (line[0] == '#') {
        if (!strcmp(line, "#screen")) screen();
        else if (sscanf(line, "#wait %d", &n1) == 1) run(n1);
        else if (sscanf(line, "#snap %255s", w) == 1)
          snap(w, (ramk == 3 ? 0x4000 : ramk == 19 ? 0x8000 : ramk == 35 ? 0xc000 : 0x10000) - 1);
        else if (sscanf(line, "#key %31s %d %d", w, &n1, &n2) == 3)
          typekey(!strcmp(w, "space") ? ' ' : !strcmp(w, "enter") ? '\n' : w[0], n1, n2);
        else { fprintf(stderr, "%s:%d: unknown command\n", argv[k], ln); return 2; }
        continue;
      }
      if (line[0] == '\\' || !line[0]) continue;   /* comment / empty line */
      for (p = line; *p; p++) {
        typekey(*p, 3, 2);
        if (p[1] == *p) run(1);
      }
      typekey('\n', 3, 2);
      /* wait until the ROM waits for a key again (loop at 0594-059E) */
      for (n1 = 0; n1 < 3000; n1++) {
        run(1);
        if (framepc >= 0x594 && framepc <= 0x59e) break;
      }
      run(2);
      if (!noerr && !input_empty()) {
        printf("%s:%d: error, the line stays in the input line:\n%s\n", argv[k], ln, line);
        screen();
        return 1;
      }
    }
    fclose(fp);
  }
  fclose(tout);
  printf("%lu frames, %d tape blocks saved\n", frames, saves);
  return 0;
}
