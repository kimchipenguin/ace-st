#!/bin/sh
# Render the Jupiter Ace logo (top one of the three in assets/Jupiter ACE Logo.pdf)
# to assets/logo.pbm: 448x103, 1 bit (1 = black; the red stripes turn black).
# Needs Ghostscript and ImageMagick; the Makefile only needs the .pbm.
set -e
cd "$(dirname "$0")/.."
t=$(mktemp -d)
gs -q -dNOPAUSE -dBATCH -sDEVICE=ppmraw -r600 -o "$t/l.ppm" "assets/Jupiter ACE Logo.pdf"
magick "$t/l.ppm" -crop 4200x1250+460+480 +repage -trim +repage \
  -colorspace gray -filter box -resize 448x -threshold 55% assets/logo.pbm
rm -rf "$t"
magick identify assets/logo.pbm
