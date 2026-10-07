#!/bin/sh
# Number and outline what the guide's captions refer to, on the raw shots that
# make-shots.sh takes. Coordinates are pixels of the 2480×1560 shots (the
# window at 2×). Re-check them by eye whenever the shots are re-taken: they are
# placed for the window as Marina 0.5.0 lays it out.
set -eu
cd "$(dirname "$0")/../../docs/images"
C='#D9480F'          # one accent, legible in print and on screen

# box x0 y0 x1 y1  — a rounded outline
# tag n x y        — a numbered disc centred at x,y
draw() {
  in="$1"; out="$2"; shift 2
  args=""
  while [ $# -gt 0 ]; do
    case "$1" in
      box) args="$args -fill none -stroke '$C' -strokewidth 6 -draw 'roundrectangle $2,$3 $4,$5 14,14'"; shift 5 ;;
      tag) r=26
           args="$args -stroke none -fill '$C' -draw 'circle $3,$4 $(($3+r)),$4'"
           args="$args -fill white -font Helvetica-Bold -pointsize 36 -gravity NorthWest -annotate +$(($3-11))+$(($4-21)) '$2'"
           shift 4 ;;
    esac
  done
  eval magick "raw/$in" $args "$out"
}

draw 01-one-session.png 01-one-session.png \
  box 30 112 386 828      tag 1 360 862 \
  box 404 100 724 152     tag 3 760 126 \
  box 404 216 2466 420    tag 2 2440 460 \
  box 2196 220 2330 270   tag 5 2386 245 \
  box 390 950 880 1000    tag 4 920 976

draw 02-context-file.png 02-context-file.png \
  box 404 268 1424 322    tag 1 368 295 \
  box 1446 100 2470 610   tag 2 2410 560

draw 03-notes-hidden.png 03-notes-hidden.png \
  box 404 282 2466 330    tag 1 2440 240 \
  box 404 334 2466 428    tag 2 368 381 \
  box 390 950 750 1000    tag 3 790 976

draw 04-settings-file.png 04-settings-file.png \
  box 404 280 1424 334    tag 1 368 307 \
  box 1446 166 2470 506   tag 2 1420 540 \
  box 1580 314 1870 394   tag 3 1910 354

draw 05-several-sessions.png 05-several-sessions.png \
  box 404 106 790 162     tag 1 830 134 \
  box 30 668 386 830      tag 2 406 860 \
  box 320 668 386 722     tag 3 420 650
ls -1 *.png
