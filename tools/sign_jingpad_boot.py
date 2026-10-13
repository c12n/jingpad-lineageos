#!/usr/bin/env python3
"""Re-sign a Magisk-patched JingPad boot.img so it passes the AVB chain check.

Magisk keeps the boot image's AVB footer but cannot re-sign it, so the hash and
signature go stale. This re-adds the footer with avbtool, keeping the stock
rollback index, properties and partition size, signed with KEY. Flash it
together with images/vbmeta-sign-root.img, whose boot chain descriptor holds the
public half of the same key (the AOSP test key by default).

usage:
  python3 sign_jingpad_boot.py magisk_patched-XXXX.img boot-magisk-signed.img
  python3 sign_jingpad_boot.py IN OUT --key other.pem --avbtool path/to/avbtool.py

Needs Python 3 and the `openssl` command (avbtool calls it to sign).
"""
import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BOOT_PARTITION_SIZE = 36700160   # boot(35 MiB) in the ud710_3h10u partition table
PAGE = 2048                      # boot image header v2 page size on the JingPad


def load_avbtool(path):
    spec = importlib.util.spec_from_file_location("avbtool", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read_footer(avb, path):
    """Return (rollback_index, [(key, value)], partition_size, salt_hex) or None."""
    try:
        footer, header, descriptors, size = avb.Avb()._parse_image(
            avb.ImageHandler(path, read_only=True))
    except Exception:
        return None
    if footer is None:
        return None
    props = [(d.key, d.value.decode() if isinstance(d.value, bytes) else d.value)
             for d in descriptors if isinstance(d, avb.AvbPropertyDescriptor)]
    salt = next((d.salt.hex() for d in descriptors
                 if isinstance(d, avb.AvbHashDescriptor) and d.partition_name == "boot"), None)
    return header.rollback_index, props, size, salt


def strip_padding(path):
    """No footer: drop zero padding so avbtool has room to append one."""
    data = open(path, "rb").read()
    end = len(data.rstrip(b"\x00"))
    end = (end + PAGE - 1) // PAGE * PAGE
    with open(path, "r+b") as f:
        f.truncate(end)
    return end


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="Magisk-patched boot image")
    ap.add_argument("output", help="signed image to flash")
    ap.add_argument("--key", default=os.path.join(HERE, "keys", "testkey_rsa4096.pem"))
    ap.add_argument("--avbtool", default=os.path.join(HERE, "avbtool.py"))
    ap.add_argument("--partition-size", type=int, default=BOOT_PARTITION_SIZE)
    ap.add_argument("--salt", help="hex salt for the hash descriptor (default: reuse the "
                                   "existing footer's salt, so output is reproducible)")
    args = ap.parse_args()

    with open(args.input, "rb") as f:
        if f.read(8) != b"ANDROID!":
            raise SystemExit(f"{args.input} is not an Android boot image")

    avb = load_avbtool(args.avbtool)
    info = read_footer(avb, args.input)
    shutil.copyfile(args.input, args.output)
    if info:
        rollback, props, part_size, salt = info
        print(f"existing footer: rollback={rollback} props={props} partition={part_size}")
    else:
        rollback, props, part_size, salt = 0, [("com.android.build.boot.os_version", "10")], 0, None
        size = strip_padding(args.output)
        print(f"no AVB footer found; image trimmed to {size} bytes, using stock props")
    if part_size and part_size != args.partition_size:
        raise SystemExit(f"footer says partition is {part_size} bytes, expected "
                         f"{args.partition_size} - is this a JingPad boot image?")

    cmd = [sys.executable, args.avbtool, "add_hash_footer",
           "--image", args.output,
           "--partition_name", "boot",
           "--partition_size", str(args.partition_size),
           "--key", args.key,
           "--algorithm", "SHA256_RSA4096",
           "--rollback_index", str(rollback)]
    for k, v in props:
        cmd += ["--prop", f"{k}:{v}"]
    salt = args.salt or salt
    if salt:
        cmd += ["--salt", salt]
    subprocess.run(cmd, check=True)

    ok, log = verify_boot(args.avbtool, args.output)
    if not ok:
        raise SystemExit("verification of the output failed:\n" + log)
    print(f"wrote {args.output} ({os.path.getsize(args.output)} bytes): "
          "signature and boot hash verified")


def verify_boot(avbtool, path):
    """avbtool checks a hash descriptor against '<partition>.img' in the image's
    own folder, so verify a copy named boot.img in a temp dir."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp_img = os.path.join(tmp, "boot.img")
        shutil.copyfile(path, tmp_img)
        r = subprocess.run([sys.executable, avbtool, "verify_image", "--image", tmp_img],
                           capture_output=True, text=True)
    log = r.stdout + r.stderr
    return r.returncode == 0 and "Successfully verified sha256 hash" in log, log


if __name__ == "__main__":
    main()
