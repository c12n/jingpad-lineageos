#!/usr/bin/env bash
# Flash a LineageOS GSI onto a JingPad A1/C1 that runs the stock Android 10 ROM.
#
# Before you start:
#   1. Bootloader unlocked (see README, "Unlock the bootloader").
#   2. Tablet on the stock Android 10 ROM (JingOS/Linux users: flash the
#      JingPad C1 Android .pac with the JingPad Flash Tool first).
#   3. Tablet in bootloader fastboot mode: `adb reboot bootloader`.
#   4. Android platform-tools (adb/fastboot) on PATH.
#
# usage:
#   ./flash_jingpad.sh lineage-20.0-YYYYMMDD-UNOFFICIAL-arm64_bvN.img[.xz]
#   ./flash_jingpad.sh --restore-stock-vbmeta     # undo the vbmeta change
set -euo pipefail

# macOS has no `timeout`; use coreutils' gtimeout if present, else run without a limit
if ! command -v timeout >/dev/null 2>&1; then
    if command -v gtimeout >/dev/null 2>&1; then timeout() { gtimeout "$@"; }
    else timeout() { shift; "$@"; }; fi
fi

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VBMETA_DISABLED="$KIT_DIR/images/vbmeta-sign-disabled.img"
VBMETA_STOCK="$KIT_DIR/images/vbmeta-sign-stock.img"
MAX_SYSTEM_MB=3990   # super(5120) - vendor(471.7) - product(617.8) - metadata headroom

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

command -v fastboot >/dev/null || die "fastboot not found - install Android platform-tools."

wait_for_fastboot() {   # $1 = yes (fastbootd) | no (bootloader)
    local want="$1" _
    for _ in $(seq 1 60); do
        if out=$(timeout 5 fastboot getvar is-userspace 2>&1); then :; fi
        if [[ "$want" == yes ]] && grep -q 'is-userspace: yes' <<<"$out"; then return 0; fi
        if [[ "$want" == no ]] && grep -qE 'is-userspace: no|FAILED|unknown' <<<"$out" \
           && [[ -n "$(timeout 5 fastboot devices 2>/dev/null)" ]]; then return 0; fi
        sleep 3
    done
    return 1
}

if [[ "${1:-}" == "--restore-stock-vbmeta" ]]; then
    step "Waiting for the tablet in bootloader fastboot mode"
    wait_for_fastboot no || die "No device in bootloader fastboot mode."
    fastboot flash vbmeta "$VBMETA_STOCK"
    echo "Stock vbmeta restored. Reflash the stock .pac if the system was replaced."
    exit 0
fi

IMG="${1:-}"
[[ -n "$IMG" && -f "$IMG" ]] || die "usage: $0 <lineage system image (.img or .img.xz)>"
[[ -f "$VBMETA_DISABLED" ]] || die "missing $VBMETA_DISABLED"

if [[ "$IMG" == *.xz ]]; then
    if [[ -f "${IMG%.xz}" ]]; then
        step "Using already-decompressed ${IMG%.xz}"
    else
        step "Decompressing $IMG"
        xz -dk "$IMG"
    fi
    IMG="${IMG%.xz}"
fi

size_mb=$(( $(stat -c %s "$IMG" 2>/dev/null || stat -f %z "$IMG") / 1048576 ))
(( size_mb <= MAX_SYSTEM_MB )) || die "System image is ${size_mb} MiB; JingPad super only has room for ~${MAX_SYSTEM_MB} MiB. Use a non-GApps (bvN) build."
# ext4 magic 0xEF53 sits at byte 1080 (superblock offset 1024 + 56)
[[ "$(head -c 1082 "$IMG" | tail -c 2 | od -An -tx1)" == *'53 ef'* ]] \
    || echo "WARNING: $IMG does not look like a raw ext4 system image (it may be sparse; that is fine for fastboot)."

step "Waiting for the tablet in bootloader fastboot mode (adb reboot bootloader)"
wait_for_fastboot no || die "No device found. Put the tablet in fastboot mode and retry."
fastboot devices
unlocked=$(timeout 5 fastboot getvar unlocked 2>&1 | awk -F': ' '/unlocked:/ {print $2}' || true)
[[ "$unlocked" == "no" ]] && die "Bootloader is locked. Unlock it first (see README)."

cat <<EOF

This will:
  * flash a vbmeta with verification disabled (keeps all stock chain keys)
  * replace Android with: $(basename "$IMG") (${size_mb} MiB)
  * require a factory reset (ALL DATA ON THE TABLET WILL BE ERASED)
Recovery path if anything goes wrong: JingPad Flash Tool + the stock .pac.
EOF
read -r -p "Type YES to continue: " ok
[[ "$ok" == "YES" ]] || die "Aborted."

step "1/4 Flashing vbmeta (verification disabled, Unisoc DHTB format)"
fastboot flash vbmeta "$VBMETA_DISABLED"

step "2/4 Rebooting into fastbootd (userspace fastboot in the stock recovery)"
fastboot reboot fastboot || true
if ! wait_for_fastboot yes; then
    echo "fastbootd did not appear automatically."
    echo "On the tablet: choose 'Enter fastboot' in the recovery menu (Vol keys + Power)."
    read -r -p "Press Enter once the screen says fastbootd... " _
    wait_for_fastboot yes || die "Still no fastbootd. Check the USB cable/driver and retry."
fi

step "3/4 Flashing the LineageOS system image into super/system"
# Keep 'product': the stock first-stage fstab mounts it without 'nofail',
# so deleting it (a common GSI tip) would bootloop this tablet.
fastboot flash system "$IMG"

step "4/4 Rebooting to recovery for the factory reset"
fastboot reboot recovery || true
cat <<'EOF'

On the tablet, in the stock recovery:
  1. Select "Wipe data/factory reset" and confirm.
  2. Select "Reboot system now".
First boot of LineageOS can take 5-10 minutes. Afterwards, hardware tweaks
live in Settings -> Phh Treble Settings.

To undo: run ./flash_jingpad.sh --restore-stock-vbmeta, then flash the stock
.pac with the JingPad Flash Tool.
EOF
