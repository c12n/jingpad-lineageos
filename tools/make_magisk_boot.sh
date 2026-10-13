#!/usr/bin/env bash
# Build a signed Magisk boot for the JingPad from stock firmware, end to end:
#   firmware .pac -> boot.img + vbmeta + boot fingerprint -> Magisk patch
#   (Magisk's own boot_patch.sh, same flags the app uses on this tablet)
#   -> re-sign (tools/sign_jingpad_boot.py) -> verify -> zip
#
# Runs on x86_64 Linux (used by the "Make Magisk boot" GitHub workflow).
# Needs: bash, python3, openssl, curl, tar, xz, debugfs (e2fsprogs).
#
# usage:
#   tools/make_magisk_boot.sh [--firmware 014|011 | --pac FILE.pac] [--magisk 31.0|latest] [--out DIR]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$REPO/tools"
FW_BASE="https://github.com/MiMillieuh/JingPad-Files/releases/download/1.0.0"
FIRMWARE=014
PAC=""
MAGISK=latest
OUT="$REPO/out"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --firmware) FIRMWARE="$2"; shift 2 ;;
        --pac) PAC="$2"; shift 2 ;;
        --magisk) MAGISK="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]] || die "needs x86_64 Linux (Magisk's host magiskboot is x86_64)."
for t in python3 openssl curl tar xz debugfs e2fsck; do
    command -v "$t" >/dev/null || die "missing tool: $t"
done

mkdir -p "$OUT"
WORK="$(mktemp -d "$OUT/work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------- firmware
if [[ -z "$PAC" ]]; then
    case "$FIRMWARE" in
        014) FW_FILE="S813_JingPad_C1_1.0.0002.014_userdebug_202204110919.tar.xz" ;;
        011) FW_FILE="S813_JingPad_C1_1.0.0002.011_user_202111011157.tar.xz" ;;
        *) die "--firmware must be 014 or 011 (or use --pac)" ;;
    esac
    log "Downloading and unpacking $FW_FILE (~1.5 GB, streamed - no .tar.xz kept)"
    mkdir -p "$WORK/pac"
    curl -fsSL --retry 3 --retry-delay 5 "$FW_BASE/$FW_FILE" | tar -xJ -C "$WORK/pac"
    PAC="$(ls "$WORK"/pac/*.pac)"
fi
[[ -f "$PAC" ]] || die "no .pac file: $PAC"
FW_NAME="$(basename "$PAC" .pac)"
FW_VER="$(sed -nE 's/.*_C1_([0-9.]+)_.*/\1/p' <<<"$FW_NAME")"
[[ -n "$FW_VER" ]] || FW_VER="custom"
echo "firmware: $FW_NAME (version $FW_VER)"

log "Extracting boot, vbmeta and the boot fingerprint from the .pac"
SUPER_OFFSET="$(python3 - "$TOOLS" "$PAC" "$WORK/fw" <<'EOF'
import importlib.util, os, sys
tools, pac, out = sys.argv[1:]
spec = importlib.util.spec_from_file_location("pac", os.path.join(tools, "pac_extract.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
info = m.parse(pac)
os.makedirs(out, exist_ok=True)
want = {"boot.img": "boot.img", "vbmeta-sign.img": "vbmeta-sign.img"}
found = {}
with open(pac, "rb") as f:
    for e in info["entries"]:
        if e["partition"] == "Super":
            found["super"] = e["offset"]
        if e["partition"] in ("BOOT", "VBMETA") and e["file"] in want:
            f.seek(e["offset"])
            open(os.path.join(out, want[e["file"]]), "wb").write(f.read(e["size"]))
            found[e["file"]] = True
missing = [k for k in ("super", "boot.img", "vbmeta-sign.img") if k not in found]
if missing:
    raise SystemExit(f"not found in .pac: {missing}")
print(found["super"])
EOF
)"
python3 "$TOOLS/lpdump.py" --offset "$SUPER_OFFSET" "$PAC" "$WORK/fw" vendor >/dev/null
debugfs -R "dump /build.prop $WORK/fw/vendor_build.prop" "$WORK/fw/vendor.img" 2>/dev/null
FINGERPRINT="$(sed -n 's/^ro.bootimage.build.fingerprint=//p' "$WORK/fw/vendor_build.prop")"
[[ -n "$FINGERPRINT" ]] || die "could not read ro.bootimage.build.fingerprint"
echo "boot fingerprint: $FINGERPRINT"
e2fsck -fn "$WORK/fw/vendor.img" >/dev/null 2>&1 || die "extracted vendor image is corrupt (e2fsck)"
rm -f "$WORK/fw/vendor.img"
[[ "$PAC" == "$WORK"/* ]] && rm -f "$PAC"     # free ~5.6 GB on small runners

log "Checking this firmware's vbmeta matches the repo's (so vbmeta-sign-root.img fits it)"
python3 - "$TOOLS" "$WORK/fw/vbmeta-sign.img" "$REPO/images/vbmeta-sign-stock.img" <<'EOF'
import importlib.util, os, sys
tools, fw, repo = sys.argv[1:]
spec = importlib.util.spec_from_file_location("avbtool", os.path.join(tools, "avbtool.py"))
avb = importlib.util.module_from_spec(spec); spec.loader.exec_module(avb)
def keys(p):
    _, _, ds, _ = avb.Avb()._parse_image(avb.ImageHandler(p, read_only=True))
    return {d.partition_name: (d.rollback_index_location, d.public_key)
            for d in ds if isinstance(d, avb.AvbChainPartitionDescriptor)}
if keys(fw) != keys(repo):
    raise SystemExit("this firmware's vbmeta chain keys differ from images/vbmeta-sign-stock.img; "
                     "build a matching root vbmeta with tools/make_jingpad_vbmeta.py first")
print("chain keys identical to images/vbmeta-sign-stock.img")
EOF

# ------------------------------------------------------------------- Magisk
if [[ "$MAGISK" == latest ]]; then
    MAGISK="$(curl -fsSL https://api.github.com/repos/topjohnwu/Magisk/releases/latest \
              | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')"
fi
MAGISK="${MAGISK#v}"
log "Downloading Magisk v$MAGISK"
APK="$WORK/Magisk-v$MAGISK.apk"
curl -fsSL --retry 3 -o "$APK" "https://github.com/topjohnwu/Magisk/releases/download/v$MAGISK/Magisk-v$MAGISK.apk"
echo "Magisk APK sha256: $(sha256sum "$APK" | cut -d' ' -f1)"

log "Patching boot.img with Magisk's boot_patch.sh"
P="$WORK/patch"; mkdir -p "$P"
python3 - "$APK" "$P" <<'EOF'
import os, sys, zipfile
apk, out = sys.argv[1:]
z = zipfile.ZipFile(apk)
names = set(z.namelist())
pick = {
    "lib/x86_64/libmagiskboot.so": "magiskboot",          # runs on this PC
    "lib/arm64-v8a/libmagiskinit.so": "magiskinit",       # goes into the tablet's boot
    "lib/arm64-v8a/libmagisk.so": "magisk",               # Magisk 28+
    "lib/arm64-v8a/libinit-ld.so": "init-ld",             # Magisk 28+
    "lib/arm64-v8a/libmagisk64.so": "magisk64",           # Magisk 26-27
    "lib/armeabi-v7a/libmagisk32.so": "magisk32",         # Magisk 26-27
    "assets/stub.apk": "stub.apk",
    "assets/boot_patch.sh": "boot_patch.sh",
    "assets/util_functions.sh": "util_functions.sh",
}
for src, dst in pick.items():
    if src in names:
        with open(os.path.join(out, dst), "wb") as f:
            f.write(z.read(src))
for need in ("magiskboot", "magiskinit", "boot_patch.sh", "util_functions.sh"):
    if not os.path.exists(os.path.join(out, need)):
        raise SystemExit(f"{need} not found in the APK - unsupported Magisk version")
EOF
chmod +x "$P"/*
cp "$WORK/fw/boot.img" "$P/boot.img"
(
    set +euo pipefail          # Magisk's scripts expect a plain shell (unset vars, failing greps)
    cd "$P"
    BOOTMODE=false
    # shellcheck disable=SC1091
    . ./util_functions.sh
    ui_print() { echo "$1"; }
    # Flags the Magisk app picks on the JingPad: system-as-root -> keep verity,
    # encrypted /data -> keep forceencrypt, separate vbmeta partition -> no vbmeta patch.
    export SOURCEDMODE=1 BOOTMODE=false KEEPVERITY=true KEEPFORCEENCRYPT=true \
           PATCHVBMETAFLAG=false RECOVERYMODE=false LEGACYSAR=false
    # shellcheck disable=SC1091
    . ./boot_patch.sh boot.img
) 2>&1 | grep -E '^- |^!' || true
[[ -f "$P/new-boot.img" ]] || die "Magisk patching failed"
(
    cd "$WORK" && mkdir chk && cd chk
    ../patch/magiskboot unpack ../patch/new-boot.img >/dev/null 2>&1
    rc=0; ../patch/magiskboot cpio ramdisk.cpio test >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 1 ]] || { echo "ERROR: patched ramdisk not recognised as Magisk (status $rc)" >&2; exit 1; }
    echo "patched ramdisk: Magisk detected"
)

log "Re-signing for the JingPad bootloader"
NAME="jingpad-magisk-boot-C1-$FW_VER"
PKG="$WORK/$NAME"; mkdir -p "$PKG"
SIGNED="boot-magisk-v$MAGISK-C1-$FW_VER-signed.img"
STOCKBOOT="boot-stock-C1-$FW_VER.img"
python3 "$TOOLS/sign_jingpad_boot.py" "$P/new-boot.img" "$PKG/$SIGNED"
cp "$WORK/fw/boot.img" "$PKG/$STOCKBOOT"

log "Verifying signing keys against the repo's vbmeta images"
python3 - "$TOOLS" "$PKG/$SIGNED" "$PKG/$STOCKBOOT" "$REPO/images" <<'EOF'
import importlib.util, os, sys
tools, magisk, stock, images = sys.argv[1:]
spec = importlib.util.spec_from_file_location("avbtool", os.path.join(tools, "avbtool.py"))
avb = importlib.util.module_from_spec(spec); spec.loader.exec_module(avb)
def boot_chain_key(p):
    _, _, ds, _ = avb.Avb()._parse_image(avb.ImageHandler(p, read_only=True))
    return next(d.public_key for d in ds
                if isinstance(d, avb.AvbChainPartitionDescriptor) and d.partition_name == "boot")
def own_key(p):
    footer, h, _, _ = avb.Avb()._parse_image(avb.ImageHandler(p, read_only=True))
    with open(p, "rb") as f:
        f.seek(footer.vbmeta_offset + avb.AvbVBMetaHeader.SIZE
               + h.authentication_data_block_size + h.public_key_offset)
        return f.read(h.public_key_size)
assert own_key(magisk) == boot_chain_key(os.path.join(images, "vbmeta-sign-root.img")), \
    "Magisk boot key does not match vbmeta-sign-root.img"
assert own_key(stock) == boot_chain_key(os.path.join(images, "vbmeta-sign-disabled.img")), \
    "stock boot key does not match vbmeta-sign-disabled.img"
print("Magisk boot <-> vbmeta-sign-root.img: key match")
print("stock boot  <-> vbmeta-sign-disabled.img: key match")
EOF

log "Packaging"
for f in "$SIGNED" "$STOCKBOOT"; do echo "$FINGERPRINT" > "$PKG/$f.fingerprint"; done
cat > "$PKG/README.txt" <<EOF
Prebuilt boot images for JingPad C1 firmware $FW_VER ($FW_NAME)
Built by tools/make_magisk_boot.sh from https://github.com/c12n/jingpad-lineageos

ONLY for tablets whose boot build matches exactly:
  adb shell getprop ro.bootimage.build.fingerprint
  -> $FINGERPRINT
(This stays the same after flashing a LineageOS GSI.)

$SIGNED
    Stock boot patched with Magisk v$MAGISK (official boot_patch.sh, flags the app
    uses on this tablet: KEEPVERITY=true, KEEPFORCEENCRYPT=true), re-signed with
    the AOSP test key. Flash with flash/flash_magisk.sh (writes images/vbmeta-sign-root.img).
    Install the matching app: https://github.com/topjohnwu/Magisk/releases/tag/v$MAGISK
    Patched on a PC, so no "pre-init" partition is recorded: modules that ship
    their own SELinux rules may need an app-patched boot instead.

$STOCKBOOT
    Untouched stock boot, to un-root: flash/flash_magisk.sh --unroot <this file>

Keep the .fingerprint files next to the images; the flash script checks them.
EOF
(cd "$PKG" && sha256sum ./*.img | sed 's# \./# #' > SHA256SUMS)
rm -f "$OUT/$NAME.zip"
(cd "$WORK" && python3 - "$NAME" "$OUT/$NAME.zip" <<'EOF'
import os, sys, zipfile
name, dst = sys.argv[1:]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, _, files in os.walk(name):
        for fn in sorted(files):
            z.write(os.path.join(root, fn))
EOF
)
cp "$PKG/SHA256SUMS" "$OUT/$NAME.SHA256SUMS"
sha256sum "$OUT/$NAME.zip" | sed "s#$OUT/##" >> "$OUT/$NAME.SHA256SUMS"
cat "$OUT/$NAME.SHA256SUMS"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "zip=$OUT/$NAME.zip"
        echo "sums=$OUT/$NAME.SHA256SUMS"
        echo "name=$NAME"
        echo "magisk=$MAGISK"
        echo "firmware=$FW_VER"
        echo "fingerprint=$FINGERPRINT"
    } >> "$GITHUB_OUTPUT"
fi
log "Done: $OUT/$NAME.zip"
