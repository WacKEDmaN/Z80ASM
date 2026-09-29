# Z80 ASM code for Amstrad CPC #
Collection of useful z80 ASM code for JavaCPC emulator/real CPC

## Disc tester (`disctest.asm`)

Floppy disc tester: scans every track and sector of a 3" or 3.5" disc
through the uPD765 FDC, draws a colour map of good/bad sectors and data
types, with per-sector info, hex dump and statistics. Supports DATA, SYSTEM,
IBM, ParaDOS, ROMDOS, +3 and custom formats, 40/80 tracks, 1/2 sides.
Press C on the map for a circular mode 1 picture of the disc (track 0 =
outer ring, sectors clockwise).
See [docs/DiscTester.md](docs/DiscTester.md).

Build with `./build.sh` (pasmo + python3) to get `build/disctest.dsk`,
then `RUN"DISCTEST"`.
