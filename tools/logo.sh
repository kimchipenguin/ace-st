#!/bin/sh
# Render the Jupiter Ace logo (top one of the three in assets/Jupiter ACE Logo.pdf)
# to assets/logo.pbm: 448x103, 1 bit (1 = black; the red stripes turn black),
# and assets/logo-med.pgm: 448x52 (half height, for ST medium; tools/medpic.py).
# Needs Ghostscript and ImageMagick; the Makefile only needs the .pbm.
set -e
cd "$(dirname "$0")/.."
t=$(mktemp -d)
gs -q -dNOPAUSE -dBATCH -sDEVICE=ppmraw -r600 -o "$t/l.ppm" "assets/Jupiter ACE Logo.pdf"
magick "$t/l.ppm" -crop 4200x1250+460+480 +repage -trim +repage \
  -colorspace gray -filter box -resize 448x -threshold 55% assets/logo.pbm
magick "$t/l.ppm" -crop 4200x1250+460+480 +repage -trim +repage \
  -colorspace gray -filter box -resize 448x52! -threshold 55% -depth 8 assets/logo-med.pgm
rm -rf "$t"
magick identify assets/logo.pbm assets/logo-med.pgm
