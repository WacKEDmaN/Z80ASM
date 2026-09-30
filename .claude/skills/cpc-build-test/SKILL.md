---
name: cpc-build-test
description: Assemble Amstrad CPC Z80 programs in this repo with pasmo, put them on .DSK images, and test them headless in the Caprice32 emulator with screenshots. Use when writing, building, running or debugging any CPC .asm program here (disctest.asm or new ones), or when you need CPC firmware/FDC/disc-format reference facts.
---

# Build and test CPC programs

## Reference first
Read `docs/notes/cpc-fdc-notes.md` before answering CPC hardware, firmware,
FDC or disc format questions; it lists verified facts and sources. Many CPC
sites (cpcwiki, seasip) are blocked from the cloud container; GitHub raw
(e.g. MAME sources) is reachable.

## Assemble
- `apt-get install -y pasmo` if missing.
- Source style: Maxam/WinAPE (`org &0800`, `&` hex, `db "text",255`,
  labels with colon, no local labels). Keep it portable: no pasmo-only
  directives.
- `pasmo prog.asm build/prog.bin build/prog.sym`. `jr` out of range is a
  hard error: change that line to `jp` (a loop over the error line number
  with sed works).
- Don't pipe the build through `tail`: it hides a failed build and you
  end up testing the old binary.
- disctest: `./build.sh` → build/disctest.bin + build/disctest.dsk.

## Disc images
- `tools/mkdsk.py program BIN DSK` writes DATA-format EDSK with the file
  (AMSDOS header, load/exec = LOAD in mkdsk.py, keep it equal to the org).
- `tools/mkdsk.py tests DIR` writes the error/format test discs.
- The `sector()`/`write_edsk()` helpers make any custom layout (ST1/ST2
  flags, None = unformatted track).

## Emulator (Caprice32, headless)
1. Build once: `apt-get install -y libsdl2-dev libfreetype-dev libpng-dev
   zlib1g-dev xvfb pkg-config`; `git clone --depth 1
   https://github.com/ColinPitrat/caprice32 ~/caprice32 && make -C ~/caprice32 -j8`
   (if apt 404s, run `apt-get update` first).
2. `. tools/emukeys.sh` then
   `tools/emutest.sh OUT "A.dsk [B.dsk]" "run\"prog${RET}$(rep $W 4)...${SHOT}${W}${QUIT}"`
3. Look at the PNGs in OUT with the Read tool; montage several with PIL to
   save round trips.
Rules: one key string only; `$W` (2s) between screenshots and before
`$QUIT`; `LIMIT=0` for long scans. Start with RUN" (quitting then resets
the CPC), or `OPENOUT"D":MEMORY &7FF:CLOSEOUT` + LOAD + CALL &800 to test returning
to BASIC.

## Known emulator limits
Caprice32 clears ST2 DD on data CRC errors, has no ID-CRC errors in READ ID
and no physical head geometry (can't test double stepping). Write down
anything new you learn in docs/notes/cpc-fdc-notes.md.
