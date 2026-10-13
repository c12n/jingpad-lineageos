#!/usr/bin/env python3
"""Build a JingPad A1/C1 (Unisoc ud710) vbmeta with AVB verification disabled.

Why this exists
---------------
Unisoc bootloaders will not accept the usual blank vbmeta made with
`fastboot --disable-verity --disable-verification`:

  * the stock image is 1 MiB with a 512-byte "DHTB" footer at 0xFFE00 that
    holds SHA-256 of the (4 KiB padded) vbmeta blob and its size, and
  * the bootloader still uses the chain-partition descriptors (boot, dtbo,
    recovery, socko, odmko, vbmeta_system, vbmeta_vendor, l_agdsp, l_pmsys)
    to check the modem/firmware partitions.

So this script copies every chain descriptor (name, rollback slot, public key)
from the stock image, sets flags=3 (hashtree + verification disabled), signs it
with the AOSP test key (an unlocked bootloader accepts any key) and rebuilds
the DHTB footer exactly like the stock file.

With --chain-key boot=KEY.pem the boot descriptor carries KEY's public half
instead, so a Magisk-patched boot re-signed with KEY (sign_jingpad_boot.py)
passes the chain check even if the bootloader ignores the disable flags.

usage:
  python3 make_jingpad_vbmeta.py --avbtool avbtool.py \
      --stock vbmeta-sign.img --key testkey_rsa4096.pem \
      --out vbmeta-sign-disabled.img
  python3 make_jingpad_vbmeta.py --avbtool avbtool.py \
      --stock vbmeta-sign.img --key testkey_rsa4096.pem \
      --chain-key boot=testkey_rsa4096.pem --out vbmeta-sign-root.img
"""
import argparse
import hashlib
import importlib.util
import os
import struct
import subprocess
import sys
import tempfile

IMAGE_SIZE = 1 << 20          # stock vbmeta-sign.img is exactly 1 MiB
FOOTER_OFFSET = IMAGE_SIZE - 512
PAD = 4096                    # stock blob is padded to 4 KiB before hashing


def load_avbtool(path):
    spec = importlib.util.spec_from_file_location("avbtool", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read_chain_descriptors(avb, stock):
    handler = avb.ImageHandler(stock, read_only=True)
    _footer, header, descriptors, _size = avb.Avb()._parse_image(handler)
    chains = [d for d in descriptors if isinstance(d, avb.AvbChainPartitionDescriptor)]
    if not chains:
        raise SystemExit("stock image has no chain descriptors - wrong file?")
    return header, chains


def dhtb_footer(blob):
    footer = bytearray(512)
    footer[0:4] = b"DHTB"
    struct.pack_into("<I", footer, 4, 1)
    footer[8:40] = hashlib.sha256(blob).digest()
    struct.pack_into("<Q", footer, 48, len(blob))
    return bytes(footer)


def check_stock_footer(stock_bytes):
    """Fail loudly if the stock file does not use the format we reproduce."""
    f = stock_bytes[FOOTER_OFFSET:]
    if len(stock_bytes) != IMAGE_SIZE or f[:4] != b"DHTB":
        raise SystemExit("stock vbmeta is not a 1 MiB DHTB-footer image")
    size = struct.unpack_from("<Q", f, 48)[0]
    if hashlib.sha256(stock_bytes[:size]).digest() != f[8:40]:
        raise SystemExit("stock DHTB hash does not verify - format differs")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--avbtool", required=True)
    ap.add_argument("--stock", required=True, help="stock vbmeta-sign.img")
    ap.add_argument("--key", required=True, help="RSA4096 PEM to sign with")
    ap.add_argument("--out", required=True)
    ap.add_argument("--flags", type=int, default=3,
                    help="AVB header flags (3 = disable hashtree + verification)")
    ap.add_argument("--chain-key", action="append", default=[], metavar="PART=PEM",
                    help="replace one chain descriptor's key with the public half of "
                         "PEM (e.g. boot=testkey_rsa4096.pem for a re-signed Magisk boot)")
    args = ap.parse_args()
    replace = dict(item.split("=", 1) for item in args.chain_key)

    stock_bytes = open(args.stock, "rb").read()
    check_stock_footer(stock_bytes)

    avb = load_avbtool(args.avbtool)
    header, chains = read_chain_descriptors(avb, args.stock)

    with tempfile.TemporaryDirectory() as tmp:
        cmd = [
            sys.executable, args.avbtool, "make_vbmeta_image",
            "--key", args.key,
            "--algorithm", "SHA256_RSA4096",
            "--flags", str(args.flags),
            "--rollback_index", str(header.rollback_index),
            "--padding_size", str(PAD),
            "--output", os.path.join(tmp, "vbmeta.img"),
        ]
        unknown = set(replace) - {c.partition_name for c in chains}
        if unknown:
            raise SystemExit(f"no chain descriptor for: {', '.join(sorted(unknown))}")
        for c in chains:
            keyfile = os.path.join(tmp, c.partition_name + ".avbpubkey")
            if c.partition_name in replace:
                subprocess.run([sys.executable, args.avbtool, "extract_public_key",
                                "--key", replace[c.partition_name], "--output", keyfile],
                               check=True)
                action = "NEW key"
            else:
                with open(keyfile, "wb") as k:
                    k.write(c.public_key)
                action = "keep key"
            cmd += ["--chain_partition",
                    f"{c.partition_name}:{c.rollback_index_location}:{keyfile}"]
            print(f"  {action} {c.partition_name:<14} slot {c.rollback_index_location}")
        subprocess.run(cmd, check=True)
        blob = open(os.path.join(tmp, "vbmeta.img"), "rb").read()

    if len(blob) % PAD or len(blob) > FOOTER_OFFSET:
        raise SystemExit(f"unexpected vbmeta blob size {len(blob)}")
    image = bytearray(IMAGE_SIZE)
    image[: len(blob)] = blob
    image[FOOTER_OFFSET:] = dhtb_footer(blob)
    with open(args.out, "wb") as o:
        o.write(image)
    check_stock_footer(bytes(image))  # self-check the file we wrote
    print(f"wrote {args.out}: {len(chains)} chain descriptors, flags={args.flags}, "
          f"blob {len(blob)} bytes + DHTB footer")


if __name__ == "__main__":
    main()
