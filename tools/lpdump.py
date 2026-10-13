#!/usr/bin/env python3
"""Tiny reader for Android dynamic-partition (super.img) metadata.

usage: lpdump.py super.img [OUTDIR name1 name2 ...]
Lists groups/partitions; optionally writes the named logical partitions out
(linear extents only) as raw images.
"""
import os
import struct
import sys

SECTOR = 512


def cstr(b):
    return b.split(b"\x00", 1)[0].decode()


def read_meta(f):
    f.seek(4096)
    geo = f.read(4096)
    magic, _ssize = struct.unpack_from("<II", geo, 0)
    if magic != 0x616C4467:
        raise SystemExit("no LP geometry magic (sparse image?)")
    max_size, slots, block = struct.unpack_from("<III", geo, 40)
    f.seek(12288)
    hdr = f.read(256)
    hmagic, major, minor, hsize = struct.unpack_from("<IHHI", hdr, 0)
    if hmagic != 0x414C5030:
        raise SystemExit("bad LP header magic")
    tables_size = struct.unpack_from("<I", hdr, 44)[0]
    descs = struct.unpack_from("<12I", hdr, 80)
    f.seek(12288 + hsize)
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
    path = sys.argv[1]
    with open(path, "rb") as f:
        m = read_meta(f)
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
        if len(sys.argv) < 4:
            return
        out = sys.argv[2]
        os.makedirs(out, exist_ok=True)
        for want in sys.argv[3:]:
            for name, attrs, first, num, grp in m["parts"]:
                if name != want:
                    continue
                with open(os.path.join(out, name + ".img"), "wb") as o:
                    for i in range(first, first + num):
                        nsec, ttype, tdata, _src = m["extents"][i]
                        if ttype != 0:
                            o.seek(nsec * SECTOR, 1)
                            continue
                        f.seek(tdata * SECTOR)
                        left = nsec * SECTOR
                        while left:
                            chunk = f.read(min(left, 16 << 20))
                            o.write(chunk)
                            left -= len(chunk)
                print("extracted", name)


if __name__ == "__main__":
    main()
