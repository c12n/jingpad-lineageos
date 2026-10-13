#!/usr/bin/env bash
# Build a LineageOS Treble GSI (arm64, system-as-root "bvN") for the JingPad A1/C1.
#
# The JingPad has no LineageOS device tree, but it is fully Treble-compliant
# (Android 10 vendor, FCM level 4, kernel 4.14.133), so the supported way to run
# LineageOS on it is a Generic System Image flashed over the stock vendor.
# This wraps AndyCGYan's lineage_build_unified recipe (TrebleDroid patches).
#
# Run on Ubuntu 22.04 x86_64 with >= 300 GB free disk and >= 16 GB RAM
# (32 GB+ recommended). Expect 2-6 hours on 16+ cores, much longer on fewer.
#
# usage:
#   ./build_lineage_gsi.sh                 # LineageOS 20 (Android 13), no Google apps
#   ./build_lineage_gsi.sh --gapps         # LineageOS 20 with MindTheGapps
#   ./build_lineage_gsi.sh --version 21    # LineageOS 21 (Android 14) - experimental on JingPad
#   ./build_lineage_gsi.sh --nosync        # rebuild without re-syncing/re-patching
#   ./build_lineage_gsi.sh --dir /data/lineage   # choose the source directory
set -euo pipefail

VERSION=20
GAPPS=false
NOSYNC=false
SRC_DIR=""
SKIP_DEPS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --gapps) GAPPS=true; shift ;;
        --nosync) NOSYNC=true; shift ;;
        --dir) SRC_DIR="$2"; shift 2 ;;
        --skip-deps) SKIP_DEPS=true; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$VERSION" in
    20) LINEAGE_BRANCH=lineage-20.0; RECIPE_BRANCH=lineage-20-td ;;
    21) LINEAGE_BRANCH=lineage-21.0; RECIPE_BRANCH=lineage-21-td
        echo "NOTE: Android 14 needs kernel >= 4.14 - the JingPad's 4.14.133 just meets it."
        echo "      It is untested on this tablet; LineageOS 20 is the safe choice." ;;
    *) echo "Only --version 20 or 21 are supported for the JingPad (kernel 4.14)." >&2
       echo "Android 15+ (LineageOS 22+) expects kernel 4.19." >&2
       exit 2 ;;
esac

SRC_DIR="${SRC_DIR:-$HOME/lineage-${VERSION}-gsi}"
TARGET_KEY=$($GAPPS && echo 64GN || echo 64VN)   # arm64_bgN / arm64_bvN
OUT_DIR="$HOME/build-output"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- host checks
log "Checking host"
[[ "$(uname -m)" == "x86_64" ]] || die "AOSP builds need an x86_64 Linux host."
mkdir -p "$SRC_DIR"
free_gb=$(df -BG --output=avail "$SRC_DIR" | tail -1 | tr -dc '0-9')
ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
swap_gb=$(awk '/SwapTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
echo "free disk: ${free_gb} GB   RAM: ${ram_gb} GB   swap: ${swap_gb} GB   cores: $(nproc)"
(( free_gb >= 250 )) || die "Need ~300 GB free in $SRC_DIR (have ${free_gb} GB)."
if (( ram_gb + swap_gb < 32 )); then
    echo "WARNING: RAM+swap is under 32 GB. Soong/metalava may be OOM-killed."
    echo "         Add swap, e.g.: sudo fallocate -l 32G /swapfile && sudo chmod 600 /swapfile"
    echo "                         sudo mkswap /swapfile && sudo swapon /swapfile"
    (( ram_gb + swap_gb >= 16 )) || die "Less than 16 GB RAM+swap - build will fail."
fi

# --------------------------------------------------------------- dependencies
if ! $SKIP_DEPS; then
    log "Installing build packages (sudo)"
    sudo apt-get update
    sudo apt-get install -y \
        bc bison build-essential ccache curl flex g++-multilib gcc-multilib git git-lfs \
        gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev lib32z1-dev libelf-dev \
        liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev libxml2 \
        libxml2-utils lzop pngcrush rsync schedtool squashfs-tools xsltproc zip zlib1g-dev \
        python-is-python3 python3 openjdk-17-jdk unzip xz-utils
    git lfs install
fi

if ! command -v repo >/dev/null; then
    log "Installing repo"
    mkdir -p "$HOME/bin"
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
    chmod a+x "$HOME/bin/repo"
    export PATH="$HOME/bin:$PATH"
fi

# git am (used to apply the TrebleDroid patches) needs an identity
git config --global user.name  >/dev/null || git config --global user.name  "JingPad Builder"
git config --global user.email >/dev/null || git config --global user.email "builder@localhost"

export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
ccache -M 50G >/dev/null 2>&1 || true

cd "$SRC_DIR"

# ---------------------------------------------------------------------- sync
if ! $NOSYNC; then
    if [[ ! -d .repo ]]; then
        log "repo init $LINEAGE_BRANCH"
        repo init -u https://github.com/LineageOS/android.git -b "$LINEAGE_BRANCH" --git-lfs
    fi
    log "Fetching the TrebleDroid/LineageOS GSI recipe ($RECIPE_BRANCH)"
    for r in lineage_build_unified lineage_patches_unified; do
        if [[ -d $r ]]; then
            git -C "$r" fetch origin "$RECIPE_BRANCH"
            git -C "$r" checkout -q -B "$RECIPE_BRANCH" "origin/$RECIPE_BRANCH"
        else
            git clone -b "$RECIPE_BRANCH" "https://github.com/AndyCGYan/$r" "$r"
        fi
    done
fi

# --------------------------------------------------------------------- build
log "Building LineageOS $VERSION GSI target $TARGET_KEY (this takes hours)"
args=(treble "$TARGET_KEY")
$NOSYNC && args+=(nosync)
# The recipe pauses for a key press when ~/.android-certs is missing (unsigned
# build). Feeding /dev/null skips that prompt so the build runs unattended.
bash lineage_build_unified/buildbot_unified.sh "${args[@]}" </dev/null

# ------------------------------------------------------------------- package
img=$(ls -t "$OUT_DIR"/lineage-*.img 2>/dev/null | head -1 || true)
[[ -n "$img" ]] || die "No system image found in $OUT_DIR - check the log above."
log "Checking the image fits the JingPad"
# super is 5120 MiB; stock vendor (471.7 MiB) + product (617.8 MiB) stay, so
# system can be at most ~4000 MiB. Stock system was 3976.6 MiB.
size_mb=$(( $(stat -c %s "$img") / 1048576 ))
echo "system image: $img (${size_mb} MiB)"
if (( size_mb > 3990 )); then
    echo "WARNING: image is ${size_mb} MiB, larger than the stock system slot (3976 MiB)."
    echo "         It may not fit in super next to vendor+product. Build without --gapps."
fi
log "Compressing for transfer"
xz -T0 -k -6 -f "$img"
(cd "$(dirname "$img")" && sha256sum "$(basename "$img")" "$(basename "$img").xz") | tee "$img.sha256"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then   # consumed by .github/workflows/build-lineage.yml
    {
        echo "image=$img"
        echo "image_xz=$img.xz"
        echo "sha256=$img.sha256"
        echo "name=$(basename "$img" .img)"
        echo "size_mb=$size_mb"
    } >> "$GITHUB_OUTPUT"
fi
echo
echo "Done. Copy $img (or the .xz) to the PC you will flash from and run"
echo "flash/flash_jingpad.sh with it."
