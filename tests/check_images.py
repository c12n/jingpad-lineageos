#!/usr/bin/env python3
"""Integrity checks for the binary images in this repo.

1. SHA256SUMS in images/ and prebuilt/ match.
2. All three vbmeta images have a valid Unisoc DHTB footer.
3. vbmeta-sign-disabled.img and vbmeta-sign-root.img are rebuilt from the stock
   vbmeta with tools/make_jingpad_vbmeta.py and must match byte for byte.
4. Key relationships hold:
   - stock boot is signed with the key stock + disabled vbmeta expect for boot
   - the Magisk boot is signed with the key vbmeta-sign-root.img expects for boot
   - root vbmeta differs from the disabled one ONLY in the boot chain key
5. Every prebuilt/*.zip: both boots verify (signature + hash), keys match the
   vbmeta images, and the fingerprint files agree.
"""
import glob
import hashlib
import importlib.util
import os
import subprocess
import sys
import tempfile
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(REPO, "tools")
IMAGES = os.path.join(REPO, "images")
KEY = os.path.join(TOOLS, "keys", "testkey_rsa4096.pem")
AVBTOOL = os.path.join(TOOLS, "avbtool.py")
failures = []


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


avb = load("avbtool", AVBTOOL)
mkv = load("make_jingpad_vbmeta", os.path.join(TOOLS, "make_jingpad_vbmeta.py"))
sign = load("sign_jingpad_boot", os.path.join(TOOLS, "sign_jingpad_boot.py"))


def check(cond, msg):
    print(("ok    " if cond else "FAIL  ") + msg)
    if not cond:
        failures.append(msg)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_sums(sumfile):
    base = os.path.dirname(sumfile)
    for line in open(sumfile):
        digest, name = line.split()
        name = name.lstrip("*")
        path = os.path.join(base, os.path.basename(name))
        label = os.path.relpath(path, REPO) if path.startswith(REPO) else os.path.basename(path)
        check(os.path.exists(path) and sha256(path) == digest, f"checksum {label}")


def chain_keys(path):
    _, header, descs, _ = avb.Avb()._parse_image(avb.ImageHandler(path, read_only=True))
    keys = {d.partition_name: (d.rollback_index_location, d.public_key)
            for d in descs if isinstance(d, avb.AvbChainPartitionDescriptor)}
    return header, keys


def signing_key(path):
    """Public key (AVB format) embedded in an image's own vbmeta struct."""
    footer, header, _, _ = avb.Avb()._parse_image(avb.ImageHandler(path, read_only=True))
    off = footer.vbmeta_offset if footer else 0
    aux = off + avb.AvbVBMetaHeader.SIZE + header.authentication_data_block_size
    with open(path, "rb") as f:
        f.seek(aux + header.public_key_offset)
        return f.read(header.public_key_size)


def main():
    print("== checksums")
    check_sums(os.path.join(IMAGES, "SHA256SUMS"))
    check_sums(os.path.join(REPO, "prebuilt", "SHA256SUMS"))

    print("== DHTB footers")
    stock = os.path.join(IMAGES, "vbmeta-sign-stock.img")
    disabled = os.path.join(IMAGES, "vbmeta-sign-disabled.img")
    root = os.path.join(IMAGES, "vbmeta-sign-root.img")
    for p in (stock, disabled, root):
        try:
            mkv.check_stock_footer(open(p, "rb").read())
            check(True, f"DHTB footer {os.path.basename(p)}")
        except SystemExit as e:
            check(False, f"DHTB footer {os.path.basename(p)}: {e}")

    print("== reproducible vbmeta images")
    with tempfile.TemporaryDirectory() as tmp:
        for out, extra in (("vbmeta-sign-disabled.img", []),
                           ("vbmeta-sign-root.img", ["--chain-key", f"boot={KEY}"])):
            dst = os.path.join(tmp, out)
            subprocess.run([sys.executable, os.path.join(TOOLS, "make_jingpad_vbmeta.py"),
                            "--avbtool", AVBTOOL, "--stock", stock, "--key", KEY,
                            "--out", dst, *extra], check=True, stdout=subprocess.DEVNULL)
            check(open(dst, "rb").read() == open(os.path.join(IMAGES, out), "rb").read(),
                  f"{out} rebuilds byte-for-byte from the stock vbmeta")

    print("== chain keys")
    s_hdr, s_keys = chain_keys(stock)
    d_hdr, d_keys = chain_keys(disabled)
    r_hdr, r_keys = chain_keys(root)
    check(s_hdr.flags == 0 and d_hdr.flags == 3 and r_hdr.flags == 3,
          "flags: stock=0, disabled=3, root=3")
    check(len(s_keys) == 9 and set(s_keys) == set(d_keys) == set(r_keys),
          "all 9 chain partitions present in every vbmeta")
    check(d_keys == s_keys, "disabled vbmeta keeps every stock chain key")
    not_boot = lambda keys: {k: v for k, v in keys.items() if k != "boot"}
    check(not_boot(r_keys) == not_boot(s_keys),
          "root vbmeta keeps every stock chain key except boot")
    test_pub = avb.RSAPublicKey(KEY).encode()
    check(r_keys["boot"][1] == test_pub and r_keys["boot"][0] == s_keys["boot"][0],
          "root vbmeta boot key = AOSP test key, same rollback slot")

    print("== prebuilt boots")
    zips = sorted(glob.glob(os.path.join(REPO, "prebuilt", "jingpad-magisk-boot-*.zip")))
    check(len(zips) >= 1, f"found {len(zips)} prebuilt zip(s)")
    for zpath in zips:
        name = os.path.basename(zpath)[:-4]
        ver = name.rsplit("-", 1)[-1]
        with tempfile.TemporaryDirectory() as tmp:
            with zipfile.ZipFile(zpath) as z:
                z.extractall(tmp)
            d = os.path.join(tmp, name)
            magisk = glob.glob(os.path.join(d, f"boot-magisk-v*-C1-{ver}-signed.img"))
            stockboot = os.path.join(d, f"boot-stock-C1-{ver}.img")
            check(len(magisk) == 1 and os.path.exists(stockboot), f"{name}: expected files present")
            if len(magisk) != 1 or not os.path.exists(stockboot):
                continue
            magisk = magisk[0]
            check_sums(os.path.join(d, "SHA256SUMS"))
            for p in (magisk, stockboot):
                ok, _ = sign.verify_boot(AVBTOOL, p)
                check(ok, f"{os.path.basename(p)} signature + hash verify")
            check(signing_key(magisk) == r_keys["boot"][1],
                  f"{ver}: Magisk boot signed with the key vbmeta-sign-root.img expects")
            check(signing_key(stockboot) == s_keys["boot"][1],
                  f"{ver}: stock boot signed with the key the stock/disabled vbmeta expects")
            fps = {open(p + ".fingerprint").read().strip() for p in (magisk, stockboot)}
            fp = next(iter(fps))
            check(len(fps) == 1 and fp.startswith("JingPad/ud710_3h10u_native/ud710_3h10u:10/"),
                  f"{ver}: fingerprint files agree ({fp.rsplit('/', 2)[-2]})")

    print()
    if failures:
        print(f"{len(failures)} check(s) failed")
        sys.exit(1)
    print("all image checks passed")


if __name__ == "__main__":
    main()
