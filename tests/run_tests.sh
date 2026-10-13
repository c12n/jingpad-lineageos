#!/usr/bin/env bash
# Dry-run tests for flash/flash_jingpad.sh and flash/flash_magisk.sh.
# A simulated fastboot/adb (tests/fake-bin) records every call; each case checks
# the exit code and the exact sequence of state-changing calls.
# Usage: tests/run_tests.sh      (needs bash, python3, openssl, xz)
#        TEST_BASH=/bin/bash tests/run_tests.sh   # run the scripts with another bash (macOS 3.2)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export FB_STATE="$WORK/state" FB_LOG="$WORK/log"
FAKE="$REPO/tests/fake-bin"
FP_014='JingPad/ud710_3h10u_native/ud710_3h10u:10/QP1A.190711.020/14011:userdebug/test-keys'
FP_OTHER='JingPad/ud710_3h10u_native/ud710_3h10u:10/QP1A.190711.020/11011:user/release-keys'
PASS=0; FAIL=0

# ------------------------------------------------------------------ fixtures
PRE="$WORK/pre"
python3 - "$REPO/prebuilt/jingpad-magisk-boot-C1-1.0.0002.014.zip" "$PRE" <<'EOF'
import sys, zipfile, os
z = zipfile.ZipFile(sys.argv[1])
for n in z.namelist():
    if n.endswith('/'):
        continue
    dst = os.path.join(sys.argv[2], os.path.basename(n))
    os.makedirs(sys.argv[2], exist_ok=True)
    open(dst, 'wb').write(z.read(n))
EOF
SIGNED="$PRE/boot-magisk-v31.0-C1-1.0.0002.014-signed.img"
STOCK="$PRE/boot-stock-C1-1.0.0002.014.img"
# unsigned/tampered: same image with one byte of the kernel flipped
UNSIGNED="$WORK/tampered.img"
python3 - "$SIGNED" "$UNSIGNED" <<'EOF'
import sys
d = bytearray(open(sys.argv[1], 'rb').read()); d[10000] ^= 0xFF
open(sys.argv[2], 'wb').write(d)
EOF
# fake GSI: 64 MiB with the ext4 magic, compressed like a real download
GSI="$WORK/lineage-test.img"
python3 - "$GSI" <<'EOF'
import sys
with open(sys.argv[1], 'wb') as f:
    f.truncate(64 << 20); f.seek(1080); f.write(b'\x53\xef')
EOF
xz -k -0 -T0 "$GSI" && rm "$GSI"
BIG="$WORK/too-big.img"                                # 4100 MiB sparse file, uses no disk
python3 -c 'import sys; open(sys.argv[1], "wb").truncate(4100 << 20)' "$BIG"
SH="${TEST_BASH:-bash}"
echo "running scripts with: $SH ($("$SH" -c 'echo $BASH_VERSION'))"

# PATH without `timeout`, like macOS
NOTIMEOUT="$WORK/notimeout"; mkdir -p "$NOTIMEOUT"
for b in bash sh cp rm mktemp grep head tail od stat seq sleep tr python3 dirname \
         basename cat xz awk sed openssl env uname ls; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$NOTIMEOUT/$b"
done
ln -sf "$FAKE/fastboot" "$NOTIMEOUT/fastboot"; ln -sf "$FAKE/adb" "$NOTIMEOUT/adb"

# --------------------------------------------------------------------- runner
# check NAME WANT_EXIT WANT_CALLS -- command...
# Env knobs per case: STDIN, START_STATE, FB_UNLOCKED, ADB_ON, ADB_FP, TEST_PATH
check() {
    local name="$1" want_rc="$2" want_calls="$3"; shift 4
    rm -f "$FB_STATE" "$FB_LOG"
    [[ -n "${START_STATE:-}" ]] && echo "$START_STATE" > "$FB_STATE"
    local rc
    PATH="${TEST_PATH:-$FAKE:$PATH}" "$@" > "$WORK/out" 2>&1 <<<"${STDIN:-}"
    rc=$?
    local calls
    calls="$(grep -vE 'getvar|devices|get-state|adb shell' "$FB_LOG" 2>/dev/null \
             | sed -e "s#$WORK/##g" -e "s#$REPO/##g" || true)"
    if [[ "$rc" == "$want_rc" && "$calls" == "$want_calls" ]]; then
        echo "ok    $name"; PASS=$((PASS + 1))
    else
        echo "FAIL  $name (exit $rc, wanted $want_rc)"
        echo "  calls wanted:"; sed 's/^/    /' <<<"$want_calls"
        echo "  calls got:";    sed 's/^/    /' <<<"$calls"
        echo "  output:";       tail -n 15 "$WORK/out" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    fi
}

GSI_FLASH="fastboot flash vbmeta images/vbmeta-sign-disabled.img
fastboot reboot fastboot
fastboot flash system lineage-test.img
fastboot reboot recovery"
ROOT_FLASH="fastboot flash vbmeta images/vbmeta-sign-root.img
fastboot flash boot pre/boot-magisk-v31.0-C1-1.0.0002.014-signed.img
fastboot reboot"

J="$REPO/flash/flash_jingpad.sh"
M="$REPO/flash/flash_magisk.sh"
echo "== flash_jingpad.sh"
STDIN=YES check "flashes vbmeta, then system in fastbootd (.xz input)" 0 "$GSI_FLASH" -- "$SH" "$J" "$GSI.xz"
STDIN=YES check "reuses an already-decompressed image"                  0 "$GSI_FLASH" -- "$SH" "$J" "$GSI.xz"
STDIN=no  check "stops unless the user types YES"                       1 ""           -- "$SH" "$J" "$GSI.xz"
STDIN=YES check "refuses an image too big for super"                    1 ""           -- "$SH" "$J" "$BIG"
STDIN=YES FB_UNLOCKED=no check "refuses on a locked bootloader"         1 ""           -- "$SH" "$J" "$GSI.xz"
check "restores the stock vbmeta" 0 "fastboot flash vbmeta images/vbmeta-sign-stock.img" -- "$SH" "$J" --restore-stock-vbmeta
STDIN=YES TEST_PATH="$NOTIMEOUT" check "works without timeout (macOS)"  0 "$GSI_FLASH" -- "$SH" "$J" "$GSI.xz"

echo "== flash_magisk.sh"
cp "$SIGNED" "$WORK/signed-nofp.img"
echo "$FP_014" > "$SIGNED.fingerprint"
ADB_ON=1 ADB_FP="$FP_014" check "fingerprint matches: reboots and flashes vbmeta-root + boot" 0 \
    "adb reboot bootloader
$ROOT_FLASH" -- "$SH" "$M" "$SIGNED"
check "already in bootloader, no adb"                 0 "$ROOT_FLASH" -- "$SH" "$M" "$SIGNED"
ADB_ON=1 ADB_FP="$FP_OTHER" check "refuses a fingerprint mismatch" 1 "" -- "$SH" "$M" "$SIGNED"
check "refuses an unsigned/tampered boot"             1 "" -- "$SH" "$M" "$UNSIGNED"
check "refuses a file that is not a boot image"       1 "" -- "$SH" "$M" "$GSI.xz"
START_STATE=fastbootd check "refuses while in fastbootd" 1 "" -- "$SH" "$M" "$SIGNED"
check "unroot: stock boot + disabled vbmeta" 0 "fastboot flash vbmeta images/vbmeta-sign-disabled.img
fastboot flash boot pre/boot-stock-C1-1.0.0002.014.img
fastboot reboot" -- "$SH" "$M" --unroot "$STOCK"
TEST_PATH="$NOTIMEOUT" check "works without timeout (macOS)" 0 "fastboot flash vbmeta images/vbmeta-sign-root.img
fastboot flash boot signed-nofp.img
fastboot reboot" -- "$SH" "$M" "$WORK/signed-nofp.img"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
