#!/usr/bin/env bash
# Root a JingPad A1/C1 (stock Android 10 or a LineageOS GSI) with Magisk.
#
# usage:
#   ./flash_magisk.sh boot-magisk-signed.img     # flash a re-signed Magisk boot
#   ./flash_magisk.sh --unroot boot-stock.img     # put the stock boot back
#
# The boot image must be re-signed with tools/sign_jingpad_boot.py first.
# If a file named <image>.fingerprint sits next to the image, the tablet's
# ro.bootimage.build.fingerprint must match it (checked over adb when available).
set -euo pipefail

# macOS has no `timeout`; use coreutils' gtimeout if present, else run without a limit
if ! command -v timeout >/dev/null 2>&1; then
    if command -v gtimeout >/dev/null 2>&1; then timeout() { gtimeout "$@"; }
    else timeout() { shift; "$@"; }; fi
fi

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AVBTOOL="$KIT_DIR/tools/avbtool.py"
VBMETA_ROOT="$KIT_DIR/images/vbmeta-sign-root.img"
VBMETA_DISABLED="$KIT_DIR/images/vbmeta-sign-disabled.img"

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
command -v fastboot >/dev/null || die "fastboot not found - install Android platform-tools."

MODE=root
if [[ "${1:-}" == "--unroot" ]]; then MODE=unroot; shift; fi
IMG="${1:-}"
[[ -n "$IMG" && -f "$IMG" ]] || die "usage: $0 [--unroot] <boot image>"
[[ "$(head -c 8 "$IMG")" == "ANDROID!" ]] || die "$IMG is not an Android boot image."

if [[ "$MODE" == root ]]; then
    VBMETA="$VBMETA_ROOT"
    if command -v python3 >/dev/null; then
        step "Checking the boot image signature"
        # avbtool hashes '<partition>.img' from the image's folder, so check a copy named boot.img
        vdir=$(mktemp -d)
        cp "$IMG" "$vdir/boot.img"
        verify_ok=true
        verify_out=$(python3 "$AVBTOOL" verify_image --image "$vdir/boot.img" 2>&1) || verify_ok=false
        rm -rf "$vdir"
        $verify_ok && grep -q "Successfully verified sha256 hash" <<<"$verify_out" \
            || die "$IMG is not signed. Run: python3 tools/sign_jingpad_boot.py <magisk_patched.img> boot-magisk-signed.img"
    fi
else
    VBMETA="$VBMETA_DISABLED"   # stock boot keys + verification off: works for stock and GSI
fi

# Fingerprint check (only when the tablet is booted with USB debugging on)
if command -v adb >/dev/null && [[ "$(timeout 5 adb get-state 2>/dev/null || true)" == "device" ]]; then
    fp=$(adb shell getprop ro.bootimage.build.fingerprint | tr -d '\r')
    echo "tablet boot build: $fp"
    if [[ -f "$IMG.fingerprint" ]]; then
        want=$(tr -d '\r\n' < "$IMG.fingerprint")
        [[ "$fp" == "$want" ]] || die "This image was made for $want - your tablet runs $fp. Patch your own boot.img instead (see README)."
    fi
    step "Rebooting to the bootloader"
    adb reboot bootloader
fi

step "Waiting for bootloader fastboot mode (adb reboot bootloader)"
for _ in $(seq 1 60); do
    [[ -n "$(timeout 5 fastboot devices 2>/dev/null)" ]] && break
    sleep 2
done
[[ -n "$(timeout 5 fastboot devices 2>/dev/null)" ]] || die "No device in fastboot mode."
if [[ "$(timeout 5 fastboot getvar is-userspace 2>&1 || true)" == *'is-userspace: yes'* ]]; then
    die "Tablet is in fastbootd. Run 'fastboot reboot bootloader' and retry."
fi

step "Flashing $(basename "$VBMETA") and $(basename "$IMG")"
fastboot flash vbmeta "$VBMETA"
fastboot flash boot "$IMG"
fastboot reboot

if [[ "$MODE" == root ]]; then
cat <<'EOF'

Done. When Android is up, open the Magisk app (v31.0 from
github.com/topjohnwu/Magisk/releases). If it asks for "additional setup",
accept - it only installs files to /data and reboots.

To update Magisk later, do NOT use "Direct Install": that writes an unsigned
boot. Patch a file in the app, re-sign it, and flash it with this script.
EOF
else
    echo; echo "Stock boot restored. Remove the Magisk app if you no longer need it."
fi
