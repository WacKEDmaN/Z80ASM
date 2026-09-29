# Reference notes: CPC floppy controller, disc formats, tools

Facts collected while writing `disctest.asm` (September 2026), with where
each one came from. "Verified" means it was checked in the Caprice32 emulator.

## uPD765 on the CPC

Source: MAME `src/devices/machine/upd765.{h,cpp}` (GitHub), cpcwiki FDC pages
(search results only; cpcwiki is blocked from the build container).

* Ports: main status register `&FB7E` (read), data register `&FB7F`, motor
  `&FA7E` (bit 0 = motor on for all drives).
* Main status: bit 7 RQM (ready for transfer), bit 6 DIO (1 = FDC→CPU),
  bit 5 EXM (execution phase), bit 4 CB (busy), bits 0–3 drive busy.
* ST0: bits 7–6 IC (00 ok, 01 abnormal, 10 invalid, 11 ready changed),
  bit 5 SE (seek end), bit 4 EC, bit 3 NR (not ready), bit 2 head,
  bits 1–0 unit.
* ST1: bit 7 EN (end of cylinder), bit 5 DE (CRC error in ID *or* data),
  bit 4 OR (overrun), bit 2 ND (no data / not found), bit 1 NW, bit 0 MA
  (missing address mark).
* ST2: bit 6 CM (deleted data mark), bit 5 DD (CRC error in data field),
  bit 4 WC (wrong cylinder), bit 1 BC (bad cylinder), bit 0 MD (missing data
  address mark).
* ST3: bit 6 WP, bit 5 RY (ready), bit 4 T0, bit 3 TS.
* Commands used (MFM bit &40): SPECIFY `&03,SRT/HUT,HLT/ND`;
  SENSE DRIVE STATUS `&04,unit`; RECALIBRATE `&07,unit`;
  SENSE INTERRUPT STATUS `&08` (returns only `&80` when nothing is pending);
  SEEK `&0F,unit,ncn`; READ ID `&4A,hd<<2|unit` → ST0 ST1 ST2 C H R N;
  READ DATA `&46,hd<<2|unit,C,H,R,N,EOT,GPL,DTL` → ST0 ST1 ST2 C H R N.
* READ DATA of one sector (EOT=R) always ends with IC=01 + EN: the CPC has
  no TC line. Treat EN on its own as success (MAME: sets EN when
  `command[4]==command[6]` and no TC).
* READ DATA with SK=0 on a deleted-data sector reads it, sets CM and stops.
* READ ID on an ID with a bad CRC returns that ID with ST1 = MA|DE|ND (MAME).
  With no ID at all it gives up after 2 index pulses with MA|ND.
* An ID CRC error during READ DATA ends the command **before** any data is
  transferred; a data CRC error arrives **after** all the data. Counting the
  bytes received tells them apart when DD is missing.
* SPECIFY units depend on the 4 MHz FDC clock on the CPC: `&A1` = 12 ms step,
  `&03` = head load + non-DMA (ND=1, required on CPC).
* The CPU must take a byte every 32 µs in MFM (cpcwiki quotes about 26 µs of
  slack); run the transfer loop with interrupts off. The loop in disctest
  (`in / jp p / and &20 / jr z / inc c / ini / inc b / dec c / res 5,h /
  inc de / jp`) is about 26 µs per byte and reacts within about 20 µs.
* Without an FDC (464 with no DDI-1) the ports read &FF: RQM and DIO always
  look set. Any "drain the result bytes" loop needs a limit.

## Disc formats

Source: ParaDOS manual (cpcwiki search result summary), AMSDOS.

| Format | IDs | Sectors | Tracks × sides |
|--------|-----|---------|----------------|
| DATA | &C1–&C9 | 9 × 512 | 40 × 1 |
| SYSTEM (VENDOR) | &41–&49 | 9 × 512 | 40 × 1, 2 reserved tracks |
| IBM | &01–&08 | 8 × 512 | 40 × 1 |
| ROMDOS D1 | &01–&09 | 9 × 512 | 80 × 2 (716K) |
| ROMDOS D2 | &21–&29 | 9 × 512 | 80 × 2 (712K) |
| ROMDOS D10 | &11–&1A | 10 × 512 | 80 × 2 (796K) |
| PARADOS 80 | &91–&9A | 10 × 512 | 80 × 1 (396K) |
| PARADOS 41 | &81–&8A | 10 × 512 | 41 × 1 (203K) |
| PARADOS 40D | &A1–&AA | 10 × 512 | 40 × 2 (396K) |

AMSDOS and ParaDOS identify a format by the lowest sector ID on the track.
Not verified here: IDs of ROMDOS D20/D40/D80. DISCTEST shows those as
CUSTOM but still scans them.

AMSDOS header: 128 bytes; 1–8 name, 9–11 type, 18 file type, 21–22 load,
24–25 length, 26–27 exec, 64–66 length (24-bit), 67–68 = 16-bit sum of bytes
0–66.

## BASIC / firmware (verified)

* `MEMORY &FFF` on its own works on a 6128. `MEMORY &FFF:LOAD"x"` fails with
  *Memory full* because AMSDOS allocates a 4K buffer below HIMEM when it opens
  the file. Fix: `OPENOUT"D":MEMORY &FFF:CLOSEOUT` first.
* A binary started with `RUN"` resets the CPC when it returns. `CALL`
  returns to BASIC normally.
* HIMEM on a 6128 with AMSDOS = 42619 (&A67B).
* TXT OUTPUT obeys control codes: 31,col,row = locate, 15,n = pen, 12 = cls.
  Use 255 as the string terminator so pen 0 / column 0 bytes are safe.
* Never print in column 20 of line 25 in mode 0 (or column 40/80 in modes 1/2):
  the next character scrolls the screen and breaks direct screen addressing.
* Mode 0 byte: left pixel in bits 7,5,3,1 (mask &AA), right pixel in bits
  6,4,2,0. SCR INK ENCODE (&BC2C) returns the byte for an ink.
* Screen address (offset 0): &C000 + (y and 7)×&800 + (y/8)×80 + x.
  Next line: H += 8; on carry add &C050.

## Tools

* `pasmo` (apt) assembles Maxam-style source (`&` hex, `db "..."`); all
  labels are global. `jr` out of range is a hard error; switch it to `jp`.
  `pasmo --amsdos` writes a lower-case header name, so tools/mkdsk.py writes
  its own header instead.
* EDSK images store per-sector ST1/ST2 and zero-size (unformatted) tracks;
  Caprice32 honours both.
* Caprice32 quirks (src/fdc.cpp): the READ DATA code does
  `if (FDC.result[RES_ST2] &= 0x40)`, which clears DD, so data CRC errors
  show as DE without DD. READ ID never reports ID CRC errors. It doesn't
  emulate seek geometry, so double stepping can't be tested with it.
* Caprice32 autotype: `\a` + CPC key code (down 117, left 118, right 119,
  up 120, ESC 130, from the `CPC_KEYS` enum). Each `-a` adds an ENTER.
  CAP32_DELAY waits `boot_time` frames. A screenshot right before CAP32_EXIT
  is lost.
