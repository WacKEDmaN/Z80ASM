#!/bin/sh
# Assemble DISCTEST and put it on a disc image (needs pasmo and python3).
set -e
mkdir -p build
pasmo disctest.asm build/disctest.bin build/disctest.sym
python3 tools/mkdsk.py program build/disctest.bin build/disctest.dsk
echo "built build/disctest.bin and build/disctest.dsk"
