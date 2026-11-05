/* ACE-ST trace oracle: replays a TRACE.BIN written by ACETRACE.PRG against
 * xAce's Z80 core (z80ops.c, cbops.c, edops.c, GPL v2+) and reports the first
 * record that differs.
 *
 * usage: oracle <ace.rom> <TRACE.BIN> [skip TRACEINT.BIN] [context]
 *
 * skip: the trace window starts after this many instructions; TRACEINT.BIN
 * lists the interrupts taken before it (24 bytes each: record number,
 * interrupted PC, full record), which are checked as well.
 *
 * Record (18 bytes, big endian): PC SP A F BC DE HL IX IY int pad.
 * F holds only S Z PV C.  int != 0: an interrupt was taken right before the
 * record (the oracle follows the trace there, as the ST timing is real time).
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
static unsigned long tstart, kbsteps, kbcalls, kbts, fnsteps, fncalls, fnts, dscalls;
static unsigned char partable[256];
static unsigned char kborig[3];

/* port reads come from TRACEIN.BIN (logged by the ST), else 255 */
static unsigned char *inlog;
static long inlen, inpos;
unsigned int in(int h, int l)
{
  (void)h; (void)l;
  return inpos < inlen ? inlog[inpos++] : 255;
}
unsigned int out(int h, int l, int a) { (void)h; (void)l; (void)a; return 0; }
void do_interrupt(void) {}
void fix_tstates(void) { tstates = 0; }
#define parity(a) (partable[a])

/* Tape traps with ACE-ST's rules (src/tape.s).  xAce's tape.c misreads the
 * end of the tape in tape_skip_block (EOF -> length -257, seeks backwards),
 * so a search for a missing file went somewhere else there. */
static FILE *tfp;
static int teof, thdr;

static int tape_rblock(int dest)
{
  int lo = fgetc(tfp), hi = fgetc(tfp), n;
  if (lo == EOF || hi == EOF) { teof = 1; return -1; }
  n = (lo | hi << 8) - 1;
  if (n <= 0) { teof = 1; return -1; }
  if (dest + n > 65536) n = 65536 - dest;
  fread(mem + dest, 1, n, tfp);
  fgetc(tfp);                           /* checksum */
  {                                     /* bytes below 0x4000 reach the mirrors */
    int k;
    for (k = dest; k < dest + n && k < 0x4000; k++) store(k, mem[k]);
  }
  return 0;
}

static void tape_load_p(char *m, int dest)
{
  (void)m;
  if (!tfp) return;
  if (getenv("TAPELOG")) printf("tape load to %04X, name %.10s\n", dest, mem + 0x2702);
  if (teof) { fseek(tfp, 0, SEEK_SET); teof = thdr = 0; }
  if (!thdr) {
    if (tape_rblock(dest)) return;
    if (!memcmp(mem + 0x2702, mem + dest + 1, 10)) thdr = 1;
    else {                              /* wrong file: skip its data block */
      int lo = fgetc(tfp), hi = fgetc(tfp);
      if (lo == EOF || hi == EOF) teof = 1;
      else fseek(tfp, lo | hi << 8, SEEK_CUR);
    }
  } else {
    tape_rblock(dest);
    thdr = 0;
  }
  if (getenv("TAPELOG")) printf("  got %02X %.10s\n", mem[dest], mem + dest + 1);
}

static void tape_save_p(char *m, int size) { (void)m; (void)size; }

typedef struct { unsigned rpc, rsp, ra, rf, rbc, rde, rhl, rix, riy, intf; } Rec;

static Rec getrec(const unsigned char *p)
{
  Rec r;
  r.rpc = p[0] << 8 | p[1];   r.rsp = p[2] << 8 | p[3];
  r.ra = p[4];                r.rf = p[5];
  r.rbc = p[6] << 8 | p[7];   r.rde = p[8] << 8 | p[9];
  r.rhl = p[10] << 8 | p[11]; r.rix = p[12] << 8 | p[13];
  r.riy = p[14] << 8 | p[15]; r.intf = p[16];
  return r;
}

static void show(const char *who, const Rec *r)
{
  printf("%-6s PC=%04X SP=%04X A=%02X F=%02X BC=%04X DE=%04X HL=%04X "
         "IX=%04X IY=%04X%s\n", who, r->rpc, r->rsp, r->ra, r->rf, r->rbc, r->rde,
         r->rhl, r->rix, r->riy, r->intf ? " int" : "");
}

int main(int argc, char **argv)
{
  FILE *fp;
  unsigned char *tr;
  long n, i;
  long skip = argc > 4 ? atol(argv[3]) : 0, total, nev = 0, ev = 0;
  int ctx = argc > 5 ? atoi(argv[5]) : argc == 4 ? atoi(argv[3]) : 8;
  long *evs = NULL;
  unsigned char *evrec = NULL;
  int evchk = 0;
  unsigned short hist[64];
  int k;

  if (argc < 3) { fprintf(stderr, "usage: oracle rom trace [context]\n"); return 2; }
  for (k = 0; k < 256; k++) {
    int b = k, p = 0;
    while (b) { p ^= b & 1; b >>= 1; }
    partable[k] = p ? 0 : 4;
  }
  for (k = 0; k < 8; k++) memptr[k] = mem + 0x2000 * k;
  memset(mem, 0xff, sizeof mem);
  fp = fopen(argv[1], "rb");
  if (!fp || fread(mem, 1, 8192, fp) != 8192) { perror(argv[1]); return 2; }
  fclose(fp);
  mem[0x18a7] = 0xed; mem[0x18a8] = 0xfc; mem[0x18a9] = 0xc9;
  mem[0x1820] = 0xed; mem[0x1821] = 0xfd; mem[0x1822] = 0xc9;
  /* ACE-ST's native keyboard scan: ED FE C9 at 0336.  The oracle runs the
     original ROM code there instead (see below) and checks the result. */
  memcpy(kborig, mem + 0x336, 3);
  mem[0x336] = 0xed; mem[0x337] = 0xfe; mem[0x338] = 0xc9;
  mem[0x4c8] = 0xed; mem[0x4c9] = 0xff;
  mem[0x84e] = 0xed; mem[0x84f] = 0xfb;

  fp = fopen(argv[2], "rb");
  if (!fp) { perror(argv[2]); return 2; }
  fseek(fp, 0, SEEK_END); n = ftell(fp) / 18; fseek(fp, 0, SEEK_SET);
  tr = malloc(n * 18);
  if (fread(tr, 18, n, fp) != (size_t)n) { perror("read"); return 2; }
  fclose(fp);
  if (skip) {
    unsigned char q[24];
    fp = fopen(argv[4], "rb");
    if (!fp) { perror(argv[4]); return 2; }
    evs = malloc(sizeof(long) * 2 * 65536);
    evrec = malloc(18 * 65536);
    while (fread(q, 24, 1, fp) == 1 && nev < 65536) {
      evs[2 * nev] = (long)q[0] << 24 | q[1] << 16 | q[2] << 8 | q[3];
      evs[2 * nev + 1] = q[4] << 8 | q[5];
      memcpy(evrec + 18 * nev++, q + 6, 18);
    }
    fclose(fp);
  }
  total = skip + n;
  {
    char tp[1024];
    strcpy(tp, argv[2]);
    if (strrchr(tp, '/')) strcpy(strrchr(tp, '/') + 1, "TAPE.ACE");
    else strcpy(tp, "TAPE.ACE");
    tfp = fopen(tp, "rb");
  }
  {
    char ip[1024];
    strcpy(ip, argv[2]);
    if (strrchr(ip, '/')) strcpy(strrchr(ip, '/') + 1, "TRACEIN.BIN");
    else strcpy(ip, "TRACEIN.BIN");
    fp = fopen(ip, "rb");
    if (fp) {
      inlog = malloc(1 << 20);
      inlen = fread(inlog, 1, 1 << 20, fp);
      fclose(fp);
    }
  }

  {
  unsigned char a, f, b, c, d, e, h, l;
  unsigned char r, a1, f1, b1, c1, d1, e1, h1, l1, i_, iff1, iff2, im;
  unsigned short pc, ix, iy, sp;
  unsigned int radjust;
  unsigned char ixoriy, new_ixoriy, intsample, op;
#define i i_
  a=f=b=c=d=e=h=l=a1=f1=b1=c1=d1=e1=h1=l1=i=r=iff1=iff2=im=0;
  ixoriy = new_ixoriy = 0;
  ix = iy = sp = pc = 0;
  radjust = 0;
#undef i
  for (i = 0; i < total; i++) {
    Rec want, got;
    int inwin = i >= skip;
    if (i == skip) tstart = tstates;
    if (inwin) want = getrec(tr + 18 * (i - skip));
    else {
      memset(&want, 0, sizeof want);
      if (ev < nev && evs[2 * ev] == i) {
        want.intf = 1;
        want.rpc = evs[2 * ev + 1];       /* checked after the step */
        evchk = 1;
        ev++;
      }
    }
    if (i > 0) {
      unsigned short start = pc;
      int kb = pc == 0x336;
      unsigned long kbt0 = tstates;
      hist[i & 63] = pc;
      int fn = pc == 0x4c8, fnfast = 0;
      /* Forth data stack: RST 10 / RST 18 natively, ED FB at 084E */
      int ds = mem[pc] == 0xd7 || mem[pc] == 0xdf ? 1 : pc == 0x84e ? 2 : 0;
      unsigned short sp0 = sp;
      if (ds == 2) { mem[0x84e] = 0x2a; mem[0x84f] = 0x3b; }
      unsigned short lastop;
      if (kb) memcpy(mem + 0x336, kborig, 3);
      if (fn) {                         /* like forth_next: all checks pass? */
        unsigned w37 = mem[0x3c37] | mem[0x3c38] << 8;
        unsigned w3b = mem[0x3c3b] | mem[0x3c3c] << 8;
        unsigned t = w37 + 11, hh = 0x1e + w3b;
        int brk = inpos < inlen && !(inlog[inpos] & 1) &&
                  inpos + 1 < inlen && !(inlog[inpos + 1] & 1);
        fnfast = (t & 0xffff) < w3b + (t >> 16) && hh < 0x10000 &&
                 hh < (unsigned short)(sp - 2) && !brk;
        mem[0x4c8] = 0x01; mem[0x4c9] = 0x0b;
      }
    again:
      lastop = pc;
      do {
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
      } while (new_ixoriy);
      /* ACE-ST runs LDIR/LDDR/CPIR/CPDR to completion in one step */
      if (pc == start && mem[start] == 0xed && (mem[start + 1] & 0xf4) == 0xb0)
        goto again;
      /* ... and DJNZ $ */
      if (pc == start && mem[start] == 0x10 && mem[start + 1] == 0xfe)
        goto again;
      /* ... and the data stack routines up to their RET */
      if (ds == 1 && !(pc == (unsigned short)(start + 1) && sp == sp0))
        goto again;
      if (ds == 2) {
        if (lastop != 0x858)
          goto again;
        mem[0x84e] = 0xed; mem[0x84f] = 0xfb;
      }
      if (ds && inwin) dscalls++;
      /* ... and the Forth checks + NEXT at 04C8 up to the JP (HL) at 04C5 */
      if (fn) {
        if (inwin) fnsteps++;
        if (fnfast && lastop != 0x4c5)
          goto again;
        if (inwin && fnfast) { fncalls++; fnts += tstates - kbt0; }
        mem[0x4c8] = 0xed; mem[0x4c9] = 0xff;
      }
      /* ... and the keyboard scan up to its RET (RET Z at 036F, RET at 0375) */
      if (kb) {
        if (inwin) kbsteps++;
        if (!((pc == 0x36f && (f & 0x40)) || pc == 0x375))
          goto again;
        if (inwin) { kbcalls++; kbts += tstates - kbt0; }
        memcpy(mem + 0x336, "\xed\xfe\xc9", 3);
        pc = 0x338;
        if (getenv("KBLOG") && i >= atol(getenv("KBLOG")))
          printf("kb rec %ld in %ld: A=%02X F=%02X BC=%04X DE=%04X HL=%04X\n",
                 i, inpos, a, f, bc, de, hl);
      }
      (void)intsample;
      if (want.intf && !inwin && pc != want.rpc) {
        printf("DRIFT: interrupt %ld at record %ld: trace PC=%04X, xace PC=%04X"
               " (previous interrupt at record %ld)\n", ev - 1, i, want.rpc, pc,
               ev > 1 ? evs[2 * ev - 4] : 0);
        { long j; for (j = i - 63; j <= i; j++) printf(" %04X", hist[j & 63]); }
        printf("\ninput pos %ld\n", inpos);
        return 1;
      }
      if (want.intf) {
        if (!iff1) { printf("record %ld: trace takes an interrupt with IFF1=0\n", i); }
        iff1 = iff2 = 0;
        push2(pc);
        pc = 0x38;
      }
    }
    if (getenv("WATCH")) {
      static int init; static unsigned char w1, w2; int wa = strtol(getenv("WATCH"), 0, 16);
      if (!init) { init = 1; w1 = mem[wa]; w2 = mem[(wa & 0x3ff) | 0x3c00]; }
      if (mem[wa] != w1 || mem[(wa & 0x3ff) | 0x3c00] != w2) {
        printf("record %ld: after %04X: [%04X]=%02X [%04X]=%02X\n", i, hist[i & 63],
               wa, mem[wa], (wa & 0x3ff) | 0x3c00, mem[(wa & 0x3ff) | 0x3c00]);
        w1 = mem[wa]; w2 = mem[(wa & 0x3ff) | 0x3c00];
      }
    }
    got.rpc = pc; got.rsp = sp; got.ra = a; got.rf = f & 0xc5;
    got.rbc = bc; got.rde = de; got.rhl = hl; got.rix = ix; got.riy = iy;
    got.intf = want.intf;
    if (evchk) {                        /* full check at the interrupt */
      evchk = 0;
      want = getrec(evrec + 18 * (ev - 1));
      got.intf = want.intf;
      if (memcmp(&got, &want, sizeof got)) {
        printf("MISMATCH at interrupt %ld, record %ld (before the window; after "
               "%04X)\n", ev - 1, i, hist[i & 63]);
        show("trace", &want);
        show("xace", &got);
        return 1;
      }
    }
    if (inwin && memcmp(&got, &want, sizeof got)) {
      long j;
      printf("MISMATCH at record %ld (after the instruction at %04X)\n", i,
             hist[i & 63]);
      for (j = i - ctx < skip ? skip : i - ctx; j < i; j++) {
        Rec p = getrec(tr + 18 * (j - skip));
        char tag[16];
        sprintf(tag, "%ld", j);
        show(tag, &p);
      }
      show("trace", &want);
      show("xace", &got);
      return 1;
    }
  }
  if (argc > 6 || (argc == 5 && 0)) {}
  {
    char mp[1024];
    FILE *mf;
    strcpy(mp, argv[2]);
    if (strrchr(mp, '/')) strcpy(strrchr(mp, '/') + 1, "TRACEMEM.BIN");
    else strcpy(mp, "TRACEMEM.BIN");
    mf = fopen(mp, "rb");
    if (mf) {
      unsigned char st[65536];
      long a0 = -1, nd = 0, q;
      if (fread(st, 1, 65536, mf) == 65536) {
        for (q = 0; q <= 65536; q++) {
          int dif = q < 65536 && st[q] != mem[q];
          if (dif) nd++;
          if (dif && a0 < 0) a0 = q;
          if (!dif && a0 >= 0) {
            printf("memory differs %04lX-%04lX (ST %02X.., xace %02X..)\n",
                   a0, q - 1, st[a0], mem[a0]);
            a0 = -1;
          }
        }
        printf("memory: %ld bytes differ\n", nd);
      }
      fclose(mf);
    }
  }
  printf("window: %.2f Z80 T-states per ACE-ST instruction\n",
         (double)(tstates - tstart) / (n > 1 ? n - 1 : 1));
  if (kbcalls)
    printf("window: %lu keyboard scans, %lu Z80 instructions, %lu T-states in them\n",
           kbcalls, kbsteps, kbts);
  if (dscalls)
    printf("window: %lu data stack pushes/pops\n", dscalls);
  if (fncalls)
    printf("window: %lu Forth NEXTs, %lu Z80 instructions, %lu T-states in them\n",
           fncalls, fnsteps, fnts);
  printf("%ld records match (after %ld unchecked, %ld interrupts)\n", n, skip, nev);
  }
  return 0;
}
