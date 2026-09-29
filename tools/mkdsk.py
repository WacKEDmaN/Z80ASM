#!/usr/bin/env python3
"""
mkdsk.py - build Amstrad CPC disc images (.DSK, extended format) for DISCTEST.

  mkdsk.py program BIN DSK      put BIN on a DATA format disc as DISCTEST.BIN
                                (AMSDOS header, load/run address &1000) so it
                                can be started with RUN"DISCTEST
  mkdsk.py tests DIR            write the test disc images used to check
                                DISCTEST in an emulator (see docs/DiscTester.md)

Images are written in the "EXTENDED CPC DSK File" format, which can hold
per-sector FDC status bytes (CRC errors, deleted data ...), odd sector sizes
and unformatted tracks.  Emulators (WinAPE, JavaCPC, Caprice32, ACE ...) and
floppy emulators (HxC, Gotek with FlashFloppy) all accept it.
"""
import random
import struct
import sys

# --------------------------------------------------------------------------
# Low level: tracks and the EDSK container
# --------------------------------------------------------------------------


def sector(c, h, r, n, data=None, st1=0, st2=0, fill=0xE5, stored=None):
    """One sector. data is padded/truncated to the stored length."""
    size = 128 << n if n < 8 else 0x1800
    if stored is None:
        stored = size
    if data is None:
        data = bytes([fill]) * stored
    data = bytes(data[:stored]) + bytes([fill]) * max(0, stored - len(data))
    return dict(C=c, H=h, R=r, N=n, st1=st1, st2=st2, data=data)


def std_track(t, side, first_id, count, n=2, fill=0xE5):
    return [sector(t, side, first_id + i, n, fill=fill) for i in range(count)]


def track_block(t, side, secs, gap3=0x4E, filler=0xE5):
    hdr = bytearray(256)
    hdr[0:12] = b"Track-Info\r\n"
    hdr[16] = t
    hdr[17] = side
    hdr[20] = secs[0]["N"] if secs else 2
    hdr[21] = len(secs)
    hdr[22] = gap3
    hdr[23] = filler
    body = bytearray()
    for i, s in enumerate(secs):
        o = 24 + i * 8
        hdr[o:o + 6] = bytes([s["C"], s["H"], s["R"], s["N"], s["st1"], s["st2"]])
        hdr[o + 6:o + 8] = struct.pack("<H", len(s["data"]))
        body += s["data"]
    blk = bytes(hdr) + bytes(body)
    pad = (-len(blk)) % 256
    return blk + bytes(pad)


def write_edsk(path, tracks, sides):
    """tracks[t][side] = list of sectors, or None for an unformatted track"""
    ntr = len(tracks)
    hdr = bytearray(256)
    hdr[0:34] = b"EXTENDED CPC DSK File\r\nDisk-Info\r\n"
    hdr[34:48] = b"mkdsk.py      "
    hdr[48] = ntr
    hdr[49] = sides
    blocks = []
    idx = 0
    for t in range(ntr):
        for s in range(sides):
            secs = tracks[t][s]
            if secs is None:
                hdr[52 + idx] = 0
            else:
                b = track_block(t, s, secs)
                hdr[52 + idx] = len(b) // 256
                blocks.append(b)
            idx += 1
    with open(path, "wb") as f:
        f.write(hdr)
        for b in blocks:
            f.write(b)


# --------------------------------------------------------------------------
# AMSDOS / CP/M file system for DATA (&C1) and SYSTEM (&41) format
# --------------------------------------------------------------------------


def amsdos_header(name, ext, load, length, execute, ftype=2):
    h = bytearray(128)
    h[0] = 0
    h[1:9] = name.upper().ljust(8).encode()[:8]
    h[9:12] = ext.upper().ljust(3).encode()[:3]
    h[18] = ftype
    h[21:23] = struct.pack("<H", load)
    h[24:26] = struct.pack("<H", length)
    h[26:28] = struct.pack("<H", execute)
    h[64:67] = struct.pack("<I", length)[:3]
    h[67:69] = struct.pack("<H", sum(h[0:67]) & 0xFFFF)
    return bytes(h)


class CpmDisc:
    """40 track, 9 x 512 byte sectors, 1K blocks, 64 directory entries."""

    def __init__(self, first_id=0xC1, reserved=0):
        self.first_id = first_id
        self.reserved = reserved
        self.tracks = [[std_track(t, 0, first_id, 9)] for t in range(40)]
        self.dir = []
        self.next_block = 2  # blocks 0,1 = directory

    def _sector(self, logical):
        t = self.reserved + logical // 9
        r = logical % 9
        secs = self.tracks[t][0]
        return next(s for s in secs if s["R"] == self.first_id + r)

    def write_block(self, block, data):
        data = data.ljust(1024, b"\x1a")
        for half in range(2):
            s = self._sector(block * 2 + half)
            s["data"] = data[half * 512:(half + 1) * 512]

    def add_file(self, name, ext, content):
        blocks = []
        for off in range(0, len(content), 1024):
            b = self.next_block
            self.next_block += 1
            self.write_block(b, content[off:off + 1024])
            blocks.append(b)
        records = (len(content) + 127) // 128
        for extent, i in enumerate(range(0, max(1, len(blocks)), 16)):
            e = bytearray(32)
            e[0] = 0
            e[1:9] = name.upper().ljust(8).encode()[:8]
            e[9:12] = ext.upper().ljust(3).encode()[:3]
            e[12] = extent
            rc = min(128, records - extent * 128)
            e[15] = rc
            for j, b in enumerate(blocks[i:i + 16]):
                e[16 + j] = b
            self.dir.append(bytes(e))

    def finish(self):
        d = b"".join(self.dir).ljust(2048, b"\xe5")
        self.write_block(0, d[:1024])
        self.write_block(1, d[1024:])
        return self.tracks


def program_disc(binfile, dskfile):
    code = open(binfile, "rb").read()
    disc = CpmDisc()
    disc.add_file("DISCTEST", "BIN",
                  amsdos_header("DISCTEST", "BIN", 0x1000, len(code), 0x1000) + code)
    write_edsk(dskfile, disc.finish(), 1)


# --------------------------------------------------------------------------
# Test discs
# --------------------------------------------------------------------------

TEXT = (b"This is a plain text file used to check that DISCTEST shows text\r\n"
        b"sectors in their own colour.  The quick brown fox jumps over the\r\n"
        b"lazy dog.  0123456789 !\"#$%&'()*+,-./:;<=>?@[]^_\r\n") * 40


def rnd(n, seed):
    r = random.Random(seed)
    return bytes(r.randrange(256) for _ in range(n))


def test_data_errors():
    """DATA format, 42 tracks, with every kind of problem on it."""
    disc = CpmDisc()
    disc.add_file("README", "TXT", TEXT)
    disc.add_file("GAME", "BIN",
                  amsdos_header("GAME", "BIN", 0x4000, 6000, 0x4000) + rnd(6000, 1))
    disc.add_file("DATA", "DAT", rnd(9000, 2))
    tr = disc.finish()
    tr += [[std_track(t, 0, 0xC1, 9)] for t in (40, 41)]

    def sec(t, r):
        return next(s for s in tr[t][0] if s["R"] == r)

    # track 20: CRC error in data field (C3), CRC error in ID (C6)
    s = sec(20, 0xC3); s["st1"] = 0x20; s["st2"] = 0x20; s["data"] = rnd(512, 3)
    s = sec(20, 0xC6); s["st1"] = 0x20; s["st2"] = 0x00
    # track 21: deleted data mark
    sec(21, 0xC5)["st2"] = 0x40
    # track 22: unformatted
    tr[22][0] = None
    # track 23: sector not found (ND) and no data address mark (MA + MD)
    s = sec(23, 0xC2); s["st1"] = 0x04
    s = sec(23, 0xC8); s["st1"] = 0x01; s["st2"] = 0x01
    # track 24: 18 x 256 byte sectors (more than 16: map grows to 16 rows)
    tr[24][0] = [sector(24, 0, 0x01 + i, 1, data=rnd(256, 100 + i)) for i in range(18)]
    # track 25: one 8K sector (N=6) as used by some protections
    tr[25][0] = [sector(25, 0, 0xC1, 6, data=rnd(6144, 7), stored=6144,
                        st1=0x20, st2=0x20)]
    # track 26: IDs with a wrong cylinder number and odd sector numbers
    tr[26][0] = [sector(99, 0, r, 2, data=rnd(512, r)) for r in (0x41, 0xC1, 0xFF, 0x00)]
    # track 27: zero filled sectors
    tr[27][0] = std_track(27, 0, 0xC1, 9, fill=0x00)
    # track 28: directory-looking sector outside the directory
    sec(28, 0xC1)["data"] = disc.tracks[0][0][0]["data"]
    return tr


def test_system():
    disc = CpmDisc(first_id=0x41, reserved=2)
    for t in (0, 1):
        for i, s in enumerate(disc.tracks[t][0]):
            s["data"] = rnd(512, 1000 + t * 16 + i)
    disc.add_file("HELLO", "TXT", TEXT[:3000])
    return disc.finish()


def test_ibm():
    return [[std_track(t, 0, 0x01, 8)] for t in range(40)]


def test_d1():
    tr = [[std_track(t, s, 0x01, 9) for s in range(2)] for t in range(80)]
    for t in (0, 1):
        for s in tr[t][0]:
            s["data"] = rnd(512, 2000 + t * 16 + s["R"])
    s = tr[45][1][4]; s["st1"] = 0x20; s["st2"] = 0x20
    tr[79][1] = None
    return tr


def test_parados():
    tr = [[std_track(t, 0, 0x91, 10)] for t in range(80)]
    s = tr[60][0][9]; s["st1"] = 0x20; s["st2"] = 0x20
    return tr


def test_unformatted():
    return [[None] for _ in range(40)]


def make_tests(outdir):
    write_edsk(f"{outdir}/test_data_errors.dsk", test_data_errors(), 1)
    write_edsk(f"{outdir}/test_system.dsk", test_system(), 1)
    write_edsk(f"{outdir}/test_ibm.dsk", test_ibm(), 1)
    write_edsk(f"{outdir}/test_d1_80t_2s.dsk", test_d1(), 2)
    write_edsk(f"{outdir}/test_parados80.dsk", test_parados(), 1)
    write_edsk(f"{outdir}/test_blank.dsk", test_unformatted(), 1)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "program":
        program_disc(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == "tests":
        make_tests(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(1)
