#!/bin/sh
# Assemble DISCTEST and put it on a disc image (needs pasmo and python3).
set -e
mkdir -p build
pasmo disctest.asm build/disctest.bin build/disctest.sym
# the results table must end below the sector buffer at &8000
end=$(awk '$1=="TABLE_END"{print $3}' build/disctest.sym | tr -d H)
if [ $((0x$end)) -gt $((0x8000)) ]; then
  echo "ERROR: results table ends at &$end, over the &8000 buffer" >&2; exit 1
fi
python3 tools/mkdsk.py program build/disctest.bin build/disctest.dsk
echo "built build/disctest.bin and build/disctest.dsk"
