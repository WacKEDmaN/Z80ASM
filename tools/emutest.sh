#!/bin/bash
# emutest.sh - run a CPC program headless in the Caprice32 emulator and take
# screenshots, so a program can be checked without a real CPC.
#
#   tools/emutest.sh OUTDIR "DRIVE_A.dsk [DRIVE_B.dsk]" KEYS
#
# KEYS is ONE string that is typed into the CPC.  Special parts (use the
# helper variables from tools/emukeys.sh):
#   $RET                   ENTER               CAP32_DELAY    wait BOOT frames
#   $UP $DN $LT $RT $ESC   CPC keys            CAP32_SCRNSHOT screenshot to OUTDIR
#   CAP32_EXIT             quit the emulator
# Rules learned the hard way:
#   * pass everything as a single -a string: every -a argument gets an ENTER
#     appended by Caprice32
#   * put a CAP32_DELAY between CAP32_SCRNSHOT and CAP32_EXIT, or the last
#     screenshot is never written
#   * screenshot files are named by the second: keep >1s (1 delay) between two
#
# Environment: CAPRICE=path to a built caprice32 checkout (default
# ~/caprice32), BOOT=frames per CAP32_DELAY (default 100 = 2s),
# LIMIT=0 to run faster than real time.
#
# Building Caprice32 (Ubuntu): apt-get install libsdl2-dev libfreetype-dev
#   libpng-dev zlib1g-dev xvfb pkg-config;
#   git clone https://github.com/ColinPitrat/caprice32 ~/caprice32; make -C ~/caprice32
set -e
CAPRICE=${CAPRICE:-$HOME/caprice32}
out=$(realpath -m "$1"); dsk=$2; keys=$3
abs=""
for d in $dsk; do abs="$abs $(realpath "$d")"; done
mkdir -p "$out"; rm -f "$out"/*.png
cd "$CAPRICE"
export SDL_AUDIODRIVER=dummy
timeout 600 xvfb-run -a ./cap32 -c "$CAPRICE/cap32.cfg" \
  -O file.sdump_dir="$out" -O sound.enabled=0 -O video.scr_style=0 \
  -O system.boot_time="${BOOT:-100}" -O system.limit_speed="${LIMIT:-1}" \
  $abs -a "$keys" > "$out/log.txt" 2>&1
ls "$out"
