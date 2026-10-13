#!/usr/bin/env python3
"""Minimal Unisoc/Spreadtrum .pac lister/extractor.

usage: pac_extract.py FILE.pac [OUTDIR [name1 name2 ...]]
Without OUTDIR it only lists entries. With names, extracts only those file names.
"""
import os
import struct
import sys


def u16str(b):
    return b.decode("utf-16-le", "ignore").split("\x00", 1)[0]


def parse(path):
    with open(path, "rb") as f:
        hdr = f.read(4096)
        version = u16str(hdr[0:48])
        size = struct.unpack_from("<I", hdr, 48)[0]
        product = u16str(hdr[52:564])
        firmware = u16str(hdr[564:1076])
        count, list_start = struct.unpack_from("<Ii", hdr, 1076)
        entries = []
        f.seek(list_start)
        for _ in range(count):
            raw_len = f.read(4)
            (elen,) = struct.unpack("<I", raw_len)
            body = raw_len + f.read(elen - 4)
            pname = u16str(body[4:516])
            fname = u16str(body[516:1028])
            hi_size, hi_off, lo_size, _flag, _check, lo_off = struct.unpack_from(
                "<IIIIII", body, 1532
            )
            entries.append(
                {
                    "partition": pname,
                    "file": fname,
                    "size": (hi_size << 32) | lo_size,
                    "offset": (hi_off << 32) | lo_off,
                }
            )
    return {
        "version": version,
        "size": size,
        "product": product,
        "firmware": firmware,
        "entries": entries,
    }


def main():
    pac = sys.argv[1]
    info = parse(pac)
    print(f"version={info['version']} product={info['product']} firmware={info['firmware']}")
    for e in info["entries"]:
        print(f"{e['partition']:<24} {e['file']:<48} {e['size']/1048576:10.1f} MB @ {e['offset']}")
    if len(sys.argv) < 3:
        return
    out = sys.argv[2]
    wanted = set(sys.argv[3:])
    os.makedirs(out, exist_ok=True)
    with open(pac, "rb") as f:
        for e in info["entries"]:
            if not e["file"] or e["size"] == 0:
                continue
            if wanted and e["file"] not in wanted:
                continue
            name = os.path.basename(e["file"])
            f.seek(e["offset"])
            remaining = e["size"]
            with open(os.path.join(out, name), "wb") as o:
                while remaining:
                    chunk = f.read(min(remaining, 16 << 20))
                    if not chunk:
                        raise SystemExit(f"truncated reading {name}")
                    o.write(chunk)
                    remaining -= len(chunk)
            print("extracted", name)


if __name__ == "__main__":
    main()
