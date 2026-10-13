#!/usr/bin/env python3
"""Tiny reader for Android dynamic-partition (super.img) metadata.

usage: lpdump.py [--offset N] super.img [OUTDIR name1 name2 ...]
Lists groups/partitions; optionally writes the named logical partitions out
(linear extents only) as raw images. --offset reads a super image embedded at
byte N of a bigger file (e.g. straight from a .pac, without extracting it).
Raw and Android sparse (simg) super images are both supported.
"""
import os
import struct
import sys

SECTOR = 512


def cstr(b):
    return b.split(b"\x00", 1)[0].decode()


SPARSE_MAGIC = 0xED26FF3A


class SparseView:
    """Read an Android sparse image (simg) as if it were the raw image, without
    unpacking it to disk. Supports RAW, FILL and DONT_CARE chunks."""

    def __init__(self, f, base=0):
        self.f = f
        f.seek(base)
        magic, _maj, _min, fhdr, chdr, blk, _blocks, nchunks, _crc = struct.unpack(
            "<IHHHHIIII", f.read(28))
        if magic != SPARSE_MAGIC:
            raise ValueError("not a sparse image")
        self.chunks = []          # (out_start, out_len, kind, file_offset_or_fill)
        pos_in, pos_out = base + fhdr, 0
        for _ in range(nchunks):
            f.seek(pos_in)
            ctype, _r, nblk, total = struct.unpack("<HHII", f.read(12))
            length = nblk * blk
            data = pos_in + chdr
            if ctype == 0xCAC1:
                self.chunks.append((pos_out, length, "raw", data))
            elif ctype == 0xCAC2:
                f.seek(data)
                self.chunks.append((pos_out, length, "fill", f.read(4)))
            elif ctype == 0xCAC3:
                self.chunks.append((pos_out, length, "zero", None))
            if ctype != 0xCAC4:   # CRC chunks carry no data
                pos_out += length
            pos_in += total
        self.size = pos_out
        self.starts = [c[0] for c in self.chunks]
        self.pos = 0

    def seek(self, pos, whence=0):
        self.pos = pos if whence == 0 else self.pos + pos

    def read(self, n):
        import bisect
        out = bytearray()
        while n > 0 and self.pos < self.size:
            i = bisect.bisect_right(self.starts, self.pos) - 1
            start, length, kind, arg = self.chunks[i]
            skip = self.pos - start
            take = min(n, length - skip)
            if kind == "raw":
                self.f.seek(arg + skip)
                out += self.f.read(take)
            elif kind == "fill":
                rep = arg * ((skip % 4 + take) // 4 + 2)
                out += rep[skip % 4: skip % 4 + take]
            else:
                out += bytes(take)
            self.pos += take
            n -= take
        return bytes(out)


def open_super(f, base=0):
    """Return (reader, base) for a raw or sparse super image at byte `base`."""
    f.seek(base)
    if struct.unpack("<I", f.read(4))[0] == SPARSE_MAGIC:
        return SparseView(f, base), 0
    return f, base


def read_meta(f, base=0):
    f.seek(base + 4096)
    geo = f.read(4096)
    magic, _ssize = struct.unpack_from("<II", geo, 0)
    if magic != 0x616C4467:
        raise SystemExit("no LP geometry magic (sparse image?)")
    max_size, slots, block = struct.unpack_from("<III", geo, 40)
    f.seek(base + 12288)
    hdr = f.read(256)
    hmagic, major, minor, hsize = struct.unpack_from("<IHHI", hdr, 0)
    if hmagic != 0x414C5030:
        raise SystemExit("bad LP header magic")
    tables_size = struct.unpack_from("<I", hdr, 44)[0]
    descs = struct.unpack_from("<12I", hdr, 80)
    f.seek(base + 12288 + hsize)
    tables = f.read(tables_size)

    def table(i):
        off, n, sz = descs[i * 3 : i * 3 + 3]
        return [tables[off + k * sz : off + (k + 1) * sz] for k in range(n)]

    parts = []
    for p in table(0):
        name = cstr(p[:36])
        attrs, first, num, grp = struct.unpack_from("<IIII", p, 36)
        parts.append((name, attrs, first, num, grp))
    extents = [struct.unpack_from("<QIQI", e, 0) for e in table(1)]
    groups = []
    for g in table(2):
        groups.append((cstr(g[:36]), struct.unpack_from("<IQ", g, 36)))
    devs = []
    for d in table(3):
        first_sec, align, align_off, size = struct.unpack_from("<QIIQ", d, 0)
        devs.append((cstr(d[24:60]), size, first_sec))
    return {
        "version": f"{major}.{minor}",
        "slots": slots,
        "max_meta": max_size,
        "block": block,
        "parts": parts,
        "extents": extents,
        "groups": groups,
        "devs": devs,
    }


def main():
    args = sys.argv[1:]
    base = 0
    if args and args[0] == "--offset":
        base = int(args[1], 0)
        args = args[2:]
    if not args:
        raise SystemExit(__doc__)
    path = args[0]
    with open(path, "rb") as raw:
        f, base = open_super(raw, base)
        if f is not raw:
            print("(sparse image - reading chunks in place)")
        m = read_meta(f, base)
        print(f"LP metadata v{m['version']}  slots={m['slots']}  block={m['block']}")
        for name, size, first in m["devs"]:
            print(f"block device: {name} size={size/1048576:.0f} MB")
        for gname, (flags, maxsz) in m["groups"]:
            print(f"group: {gname} max={maxsz/1048576:.0f} MB")
        for name, attrs, first, num, grp in m["parts"]:
            secs = sum(m["extents"][i][0] for i in range(first, first + num))
            print(
                f"partition: {name:<16} group={m['groups'][grp][0]:<20} "
                f"size={secs*SECTOR/1048576:8.1f} MB attrs={attrs:#x}"
            )
        if len(args) < 3:
            return
        out = args[1]
        os.makedirs(out, exist_ok=True)
        for want in args[2:]:
            for name, attrs, first, num, grp in m["parts"]:
                if name != want:
                    continue
                with open(os.path.join(out, name + ".img"), "wb") as o:
                    for i in range(first, first + num):
                        nsec, ttype, tdata, _src = m["extents"][i]
                        if ttype != 0:
                            o.seek(nsec * SECTOR, 1)
                            continue
                        f.seek(base + tdata * SECTOR)
                        left = nsec * SECTOR
                        while left:
                            chunk = f.read(min(left, 16 << 20))
                            if not chunk:
                                raise SystemExit(f"{name}: image ends early (truncated?)")
                            o.write(chunk)
                            left -= len(chunk)
                print("extracted", name)


if __name__ == "__main__":
    main()
