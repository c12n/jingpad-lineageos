**This project was made with Claude Ai**

> [!WARNING]
> **Disclaimer — use at your own risk.** Everything here was built and checked
> against the stock JingPad firmware and dry-run tested, but it has **not been
> tested on a real tablet yet**. Flashing firmware can erase all your data and
> can leave the tablet unbootable until you restore it. Read each step before
> running it, and keep the stock firmware and flash tool (step 1) ready before
> you touch anything. No warranty of any kind: you are responsible for your device.

# LineageOS + Magisk for the JingPad A1 / C1

Run **LineageOS 20 (Android 13)** on the JingPad A1 or C1 and root it with
**Magisk**, using only the stock Android 10 recovery. No custom recovery, no
device tree needed.

This repo has:
* a script that **compiles** LineageOS 20 (or 21) for the JingPad
* a **vbmeta image made for the JingPad's Unisoc bootloader**, which rejects the usual blank vbmeta
* **flash scripts** for Linux, macOS and Windows that do every fastboot step for you, with safety checks
* **Magisk tools**: a signer that makes a patched boot acceptable to the bootloader, plus a
  prebuilt rooted boot for firmware 1.0.0002.014 (in [`prebuilt/`](prebuilt/))
* small tools to unpack JingPad firmware yourself

---

## Contents
1. [How it works (short version)](#how-it-works-short-version)
2. [What you need](#what-you-need)
3. [Step 1 – Get the stock firmware and flash tool (your safety net)](#step-1--get-the-stock-firmware-and-flash-tool-your-safety-net)
4. [Step 2 – Put stock Android 10 on the tablet](#step-2--put-stock-android-10-on-the-tablet)
5. [Step 3 – Unlock the bootloader](#step-3--unlock-the-bootloader)
6. [Step 4 – Get a LineageOS system image](#step-4--get-a-lineageos-system-image)
7. [Step 5 – Flash LineageOS](#step-5--flash-lineageos)
8. [Step 6 – Root with Magisk](#step-6--root-with-magisk)
9. [Undo / restore stock](#undo--restore-stock)
10. [Troubleshooting](#troubleshooting)
11. [Technical details](#technical-details)
12. [Repository layout](#repository-layout)
13. [Credits](#credits)

---

## How it works (short version)

The JingPad (Unisoc T7510, platform `ud710`) has no official LineageOS support,
but its Android 10 firmware is **Project Treble** compliant. So LineageOS is
built as a **GSI** (Generic System Image) and written over only the `system`
partition. The stock kernel, drivers (`vendor`), boot and recovery stay.

| | Stock JingPad firmware |
|---|---|
| Android | 10 (`QP1A.190711.020`, Dec 2021 security patch) |
| Kernel | 4.14.133 |
| Treble | yes, VINTF target level 4 |
| Partition style | non-A/B, system-as-root, dynamic `super` partition (5120 MiB) |
| Recovery | stock Android 10 recovery, which includes **fastbootd** |

### Which LineageOS versions can run?
Android's network stack checks the kernel version, and the JingPad's kernel is 4.14:

| LineageOS | Android | Needs kernel | On the JingPad |
|---|---|---|---|
| **20** | 13 | 4.9 or newer | ✅ **Supported, recommended** |
| 21 | 14 | 4.14 or newer | ⚠️ Just meets it, experimental |
| 22 and later | 15+ | 4.19 or newer | ❌ Not supported |

### Why the Android 10 recovery is enough
You never flash a zip. The stock recovery contains **fastbootd**, a fastboot mode
that can write into the `super` partition. The scripts use it to write the
LineageOS `system` image directly.

---

## What you need

**Hardware**
* JingPad A1 or C1, charged above 50 %
* USB-C data cable
* A PC: Windows, Linux or macOS. Windows is needed for the stock flash tool (the safety net).

**Software on the PC**

| Tool | Needed for | How to get it |
|---|---|---|
| Android platform-tools (`adb`, `fastboot`) | all flashing | Windows/Linux/macOS: download from https://developer.android.com/tools/releases/platform-tools and unzip. Linux: or `sudo apt install adb fastboot`. macOS: or `brew install android-platform-tools` |
| This repository | everything | **Code → Download ZIP** on GitHub, or `git clone https://github.com/c12n/jingpad-lineageos` |
| Python 3 + `openssl` | Magisk step only | Linux/macOS usually have both. Windows: Python from https://www.python.org (tick "Add to PATH") and `openssl` from Git for Windows (https://git-scm.com) |
| `xz` | unpacking `.img.xz` downloads | Linux: included. macOS: `brew install xz`. Windows: 7-Zip |
| JingPad Flash Tool | restoring stock (Windows) | see step 1 |

Make sure `adb` and `fastboot` work from a terminal:
```
adb version
fastboot --version
```
On Windows, either add the platform-tools folder to PATH or run the commands
from inside that folder.

**On the tablet**: Settings → About → tap **Build number** 7 times, then in
**Developer options** turn on **USB debugging**. Plug in the cable and accept the
"Allow USB debugging?" prompt. `adb devices` should then list the tablet.

---

## Step 1 – Get the stock firmware and flash tool (your safety net)

Jingling's website is gone, but the files are preserved in
[MiMillieuh/JingPad-Files releases](https://github.com/MiMillieuh/JingPad-Files/releases/tag/1.0.0).
Download:

| File | What it is |
|---|---|
| `JingPad.Flash.Tool.zip` | Windows flash tool for Unisoc `.pac` firmware |
| `S813_JingPad_C1_1.0.0002.014_userdebug_202204110919.tar.xz` | **Stock Android 10, recommended** (userdebug build, works on A1 and C1) |
| `S813_JingPad_C1_1.0.0002.011_user_202111011157.tar.xz` | Older stock Android (user build) |
| `S813_Jingling_A1_20220119_1812_uMCP_user.tar.xz` | JingOS (Linux), to go back to Linux |

Extract the `.tar.xz` to get a `.pac` file (7-Zip on Windows, `tar -xJf file.tar.xz` on Linux/macOS).
**Keep the flash tool and the `.pac` safe.** Together they restore the tablet
from almost anything, including a bootloop.

---

## Step 2 – Put stock Android 10 on the tablet

*Skip this if your tablet already runs JingPad's Android 10.*
If it runs JingOS (Linux), you must first flash the Android `.pac`. **This erases the tablet.**

1. On Windows, unzip `JingPad.Flash.Tool.zip` and install any USB driver it includes.
2. Start the flash tool (Unisoc tools are usually `ResearchDownload.exe` or
   `UpgradeDownload.exe`). Load the `.pac` with the **Load packet** button (gear or
   folder icon), then press **Start downloading** (play icon).
3. Power the tablet **off**. Connect it by USB while it is off. On Unisoc devices
   this usually means holding **Volume Down** while plugging in the cable; follow any
   instructions that came with the flash tool.
4. Wait for the tool to report **Passed**, unplug, and boot. First boot takes a few minutes.

---

## Step 3 – Unlock the bootloader

*Skip this if your bootloader is already unlocked.* **Unlocking erases the tablet.**

1. Developer options → turn on **USB debugging**, and **OEM unlocking** if your build shows that option.
2. Run `adb reboot bootloader`. The tablet restarts into fastboot mode.
3. On the PC, open **Google Chrome** (it needs WebUSB) at
   https://deadman96385.github.io/jingpad-unlock/subut/
4. Click **Connect**, pick the tablet, then click **Unlock**.
5. On the tablet, confirm with **Volume Down** when asked.

Check: `fastboot getvar unlocked` should say `yes` (some Unisoc bootloaders don't
report it; that's fine if the unlock tool succeeded).

---

## Step 4 – Get a LineageOS system image

Choose **A (compile it yourself)** or **B (download prebuilt)**. Both give the same
kind of file: an `arm64_bvN` system image (arm64, system-as-root, no Google apps).

### A) Compile it yourself

You need an **x86_64 Linux computer or cloud VM**. Phones and normal laptops are too small:

| | Minimum | Recommended |
|---|---|---|
| OS | Ubuntu 22.04 | Ubuntu 22.04 |
| CPU | 8 cores | 16+ cores |
| RAM (+ swap) | 16 GB | 32–64 GB |
| Free disk | 300 GB SSD | 400 GB SSD |
| Time | ~8–12 h | ~2–4 h |

A rented cloud VM (for example 16 vCPU / 64 GB RAM / 400 GB SSD) works well.
Free GitHub Actions runners don't have enough disk.

```bash
git clone https://github.com/c12n/jingpad-lineageos
cd jingpad-lineageos/build

./build_lineage_gsi.sh                  # LineageOS 20, no Google apps  (recommended)
./build_lineage_gsi.sh --gapps          # LineageOS 20 with MindTheGapps
./build_lineage_gsi.sh --version 21     # LineageOS 21 / Android 14 (experimental)
./build_lineage_gsi.sh --dir /data/lin  # put the ~300 GB source tree somewhere else
./build_lineage_gsi.sh --nosync         # rebuild later without re-downloading
```

What the script does:
1. Checks disk/RAM and warns if you need swap (it prints the commands to add 32 GB).
2. Installs the build packages with `apt` (asks for your sudo password) and the `repo` tool.
3. Downloads the LineageOS source (`lineage-20.0`) and AndyCGYan's TrebleDroid GSI recipe.
4. Applies the GSI patches and builds the `arm64_bvN` system image.
5. Checks the image fits the JingPad's `super` partition (max ~3990 MiB).
6. Writes it to `~/build-output/lineage-20.0-<date>-UNOFFICIAL-arm64_bvN.img`,
   plus a compressed `.img.xz` and a `.sha256` file.

Copy the `.img.xz` to the PC you flash from.

### B) Download a prebuilt image (no compiling)

AndyCGYan publishes the same TrebleDroid-based LineageOS builds:
https://sourceforge.net/projects/andyyan-gsi/files/lineage-20-td/

Download the newest file whose name contains **`arm64_bvN`** and ends in `.img.xz`.
`bgN` includes Google apps; use it only if it stays under ~3990 MiB once unpacked.

---

## Step 5 – Flash LineageOS

> **This erases all data on the tablet.**

1. Boot the tablet into Android, with USB debugging on, and connect it.
2. Put it in fastboot mode:
   ```
   adb reboot bootloader
   ```
3. Run the flash script from the repo folder.

   **Linux / macOS**
   ```bash
   ./flash/flash_jingpad.sh ~/Downloads/lineage-20.0-XXXXXXXX-UNOFFICIAL-arm64_bvN.img.xz
   ```
   **Windows** (unpack the `.xz` with 7-Zip first)
   ```bat
   flash\flash_jingpad.bat C:\Users\you\Downloads\lineage-20.0-XXXXXXXX-UNOFFICIAL-arm64_bvN.img
   ```
4. Type `YES` when asked. The script then:
   1. flashes `images/vbmeta-sign-disabled.img` → `vbmeta` (turns off verification so a non-stock system can boot),
   2. reboots into **fastbootd**,
   3. flashes the LineageOS image → `system` (keeping `product`, see [why](#technical-details)),
   4. reboots into recovery.
5. If the tablet shows the **recovery menu instead of "fastbootd"** at step 4.2, use
   the volume keys to select **Enter fastboot**, press **Power**, and the script continues.
6. In the stock recovery (volume keys move, **Power** selects):
   **Wipe data/factory reset** → confirm → **Reboot system now**.
7. The first boot takes **5–10 minutes**. That's normal.

<details>
<summary>Prefer to type the commands yourself?</summary>

```bash
adb reboot bootloader
fastboot flash vbmeta images/vbmeta-sign-disabled.img
fastboot reboot fastboot            # wait until the screen says fastbootd
fastboot flash system lineage-20.0-XXXXXXXX-UNOFFICIAL-arm64_bvN.img
fastboot reboot recovery            # then Wipe data/factory reset, Reboot system now
```
**Do not** run `fastboot delete-logical-partition product`: the JingPad bootloops without `product`.
</details>

### After the first boot
* GSI hardware fixes are in **Settings → Phh Treble Settings**. Try these first if
  something like brightness, audio or Bluetooth misbehaves.
* Google apps: build with `--gapps`, or flash a `bgN` image (if it fits).

---

## Step 6 – Root with Magisk

Works on **stock Android 10** and on **LineageOS** from step 5. A GSI doesn't
replace `boot`, so the boot image is the same in both cases.

**Why the JingPad needs extra steps:** Magisk patches `boot.img` but can't re-sign
it. The Unisoc bootloader may check `boot` against a key stored in `vbmeta`. This repo handles both parts:
* `tools/sign_jingpad_boot.py` re-signs the patched boot.
* `images/vbmeta-sign-root.img` expects the re-signing key for `boot` and keeps every other key stock.

First find your boot build:
```
adb shell getprop ro.bootimage.build.fingerprint
```

### Option 1 – Fast path (firmware 1.0.0002.014 only)
Use this **only** if the command above prints exactly:
```
JingPad/ud710_3h10u_native/ud710_3h10u:10/QP1A.190711.020/14011:userdebug/test-keys
```
1. Unzip [`prebuilt/jingpad-magisk-boot-C1-1.0.0002.014.zip`](prebuilt/jingpad-magisk-boot-C1-1.0.0002.014.zip)
   into the repo folder (it's included when you clone or download the repo). Keep the
   `.fingerprint` files next to the images.
2. Flash it:
   ```bash
   ./flash/flash_magisk.sh jingpad-magisk-boot-C1-1.0.0002.014/boot-magisk-v31.0-C1-1.0.0002.014-signed.img   # Linux/macOS
   flash\flash_magisk.bat jingpad-magisk-boot-C1-1.0.0002.014\boot-magisk-v31.0-C1-1.0.0002.014-signed.img  # Windows
   ```
   * **Linux/macOS:** if the tablet is booted with USB debugging on, the script checks the
     fingerprint over adb (it refuses on a mismatch) and reboots to the bootloader by itself.
   * **Windows:** run `adb reboot bootloader` first. The script shows the expected
     fingerprint and asks you to type `YES` if yours matches.

   Rooting does **not** erase your data.
3. Install the **Magisk v31.0** app from https://github.com/topjohnwu/Magisk/releases/tag/v31.0
4. Open Magisk. If it asks for **additional setup**, accept. It only sets up files and reboots.

> This prebuilt image was patched on a PC, so it has no "pre-init" partition
> recorded. Modules that bring their own SELinux rules may not fully work. Use
> Option 2 if you need those.

### Option 2 – Patch your own boot (any firmware)
1. Install the Magisk app from https://github.com/topjohnwu/Magisk/releases on the tablet.
2. Get your current `boot.img`, either:
   * from the `.pac` you flashed:
     ```bash
     python3 tools/pac_extract.py S813_JingPad_C1_....pac out boot.img     # writes out/boot.img
     ```
   * or straight from the tablet, if it allows root adb (the userdebug stock ROM, or
     LineageOS with **Developer options → Rooted debugging** on):
     ```bash
     adb root
     adb pull /dev/block/by-name/boot boot.img
     ```
3. Copy it to the tablet and patch it:
   ```bash
   adb push boot.img /sdcard/Download/
   ```
   In Magisk: **Install → Select and Patch a File** → pick `Download/boot.img` → **Let's go**.
4. Copy the result back. The name is printed in Magisk, e.g. `magisk_patched-31000_AbCdE.img`:
   ```bash
   adb pull /sdcard/Download/magisk_patched-31000_AbCdE.img
   ```
5. Re-sign it:
   ```bash
   python3 tools/sign_jingpad_boot.py magisk_patched-31000_AbCdE.img boot-magisk-signed.img
   ```
   It should end with `signature and boot hash verified`.
6. Flash it (on Windows, run `adb reboot bootloader` first):
   ```bash
   ./flash/flash_magisk.sh boot-magisk-signed.img       # Linux/macOS
   flash\flash_magisk.bat boot-magisk-signed.img        # Windows
   ```
7. Open Magisk and accept **additional setup** if asked.

### Updating Magisk later
**Never use "Direct Install"** in the Magisk app. It writes an unsigned boot that
the JingPad may refuse. Instead repeat Option 2 steps 3–6 with your
**stock** `boot.img`.

### Un-root
```bash
./flash/flash_magisk.sh --unroot jingpad-magisk-boot-C1-1.0.0002.014/boot-stock-C1-1.0.0002.014.img   # or your own stock boot.img
```
This puts the stock boot back, together with the verification-disabled vbmeta, so LineageOS keeps booting.

---

## Undo / restore stock

| What you want | How |
|---|---|
| Undo only the vbmeta change | `./flash/flash_jingpad.sh --restore-stock-vbmeta` (tablet in fastboot mode) |
| Remove Magisk | `./flash/flash_magisk.sh --unroot <stock boot.img>` |
| Back to stock Android 10 | Flash the C1 Android `.pac` with the JingPad Flash Tool ([step 2](#step-2--put-stock-android-10-on-the-tablet)) |
| Back to JingOS (Linux) | Flash the A1 JingOS `.pac` with the JingPad Flash Tool |

Manual vbmeta restore: `fastboot flash vbmeta images/vbmeta-sign-stock.img`.

---

## Troubleshooting

**`fastboot devices` shows nothing (Windows)**
Install a USB driver: try the driver bundled with the JingPad Flash Tool, or Google's
USB driver from the platform-tools page. Then try another cable or port, and avoid USB hubs.

**`adb devices` shows `unauthorized`**
Unlock the tablet and accept the "Allow USB debugging?" prompt.

**The script says the image is too large / `fastboot flash system` fails with a space error**
The `super` partition fits a system image of about 3990 MiB. Use an `arm64_bvN`
(no Google apps) image. Do **not** delete `product` to make space.

**`fastboot reboot fastboot` goes to the recovery menu**
Select **Enter fastboot** in that menu; the script waits for it.

**Bootloop or stuck on the logo after flashing LineageOS**
1. Make sure you did **Wipe data/factory reset** in recovery after flashing.
2. Give the first boot 10 minutes.
3. Still stuck: restore with the flash tool and the `.pac` ([Undo](#undo--restore-stock)).
   Optionally try another LineageOS image (an older build, or LineageOS 21 → 20).

**Bootloop after flashing Magisk**
Run `./flash/flash_magisk.sh --unroot <stock boot.img>` in fastboot mode, or restore with the `.pac`.

**`sign_jingpad_boot.py` says `openssl` not found (Windows)**
Install Git for Windows and add `C:\Program Files\Git\usr\bin` to PATH, or run the command in **Git Bash**.

**Build fails with "killed" / out of memory**
Add swap as the script suggests, then rerun with `--nosync` to skip re-downloading.

**Build fails while applying patches**
Delete the `lineage_build_unified` and `lineage_patches_unified` folders in the
source directory and rerun the script without `--nosync`, so it fetches fresh copies.

---

## Technical details

Everything below was read from the stock firmware
`S813_JingPad_C1_1.0.0002.014_userdebug` with the tools in `tools/`.

**Firmware layout.** The `.pac` (Unisoc format `BP_R2.0.1`, product `ud710_3h10u`)
contains 50 partitions. The 5120 MiB `super` holds `system` (3976.6 MiB), `vendor`
(471.7 MiB) and `product` (617.8 MiB) in group `group_unisoc`, without slot
suffixes: non-A/B. `boot` uses header v2 with a raw `Image` of Linux 4.14.133.

**Why `product` must stay.** The first-stage fstab inside `boot` mounts
`system`, `vendor` and `product` as `logical,first_stage_mount` **without
`nofail`**. If `product` is missing, first-stage mount fails and the tablet
bootloops. That's why the common GSI advice to delete `product` must not be followed here.

**Why a normal disabled vbmeta doesn't work.** The stock `vbmeta-sign.img` is
exactly 1 MiB:
* the AVB `vbmeta` blob, padded to 4 KiB (12288 bytes), signed SHA256_RSA4096
* nine **chain descriptors**: `boot`, `dtbo`, `recovery`, `socko`, `odmko`,
  `vbmeta_system`, `vbmeta_vendor`, `l_agdsp`, `l_pmsys`. The last two are modem/DSP
  firmware the bootloader checks.
* a 512-byte Unisoc **`DHTB` footer at `0xFFE00`**: magic `DHTB`, version 1,
  SHA-256 of the padded blob, and its size (`0x3000`)

`tools/make_jingpad_vbmeta.py` copies all nine chain descriptors with their
original keys, sets flags = 3 (hashtree and verification disabled), signs with the
AOSP test key and rebuilds the `DHTB` footer. It first confirms the footer format
on your stock file. `--chain-key boot=KEY.pem` swaps only the boot key, which is
how `vbmeta-sign-root.img` is made.

**What was verified (without a tablet):**
* The `DHTB` footer hash and size formula reproduces the stock file exactly.
* Both generated vbmetas pass avbtool signature checks and are byte-for-byte reproducible.
* `vbmeta-sign-disabled.img`: the stock boot, dtbo, recovery, socko, odmko,
  vbmeta_system and vbmeta_vendor each match their chain key and self-verify.
* `vbmeta-sign-root.img`: avbtool follows the whole chain and verifies the
  re-signed Magisk boot, then dtbo, recovery, socko, odmko, vbmeta_system → system +
  product, vbmeta_vendor → vendor. The **unsigned** Magisk boot fails the same check.
* Magisk v31.0's own `boot_patch.sh` patched the stock boot with the flags the app
  uses on this tablet (`KEEPVERITY=true`, `KEEPFORCEENCRYPT=true`). The stock
  recovery contains `fastbootd`.
* The flash scripts were dry-run against simulated `fastboot`/`adb` (right mode
  for each step, oversized images refused, unsigned or mismatched boot images refused,
  restore paths, macOS without `timeout`), and pass `shellcheck`.

**Not verified:** real-hardware behaviour of the bootloader, LineageOS hardware
support (camera, audio, sensors, Bluetooth) on this Unisoc vendor, and the
LineageOS 21 experiment.

**Kernel ceiling.** From LineageOS's `NetBpfLoad.cpp`: Android T requires kernel
4.9, U requires 4.14, V requires 4.19. The JingPad has 4.14.133.

---

## Repository layout

```
build/build_lineage_gsi.sh        compile LineageOS 20/21 GSI (Ubuntu 22.04)
flash/flash_jingpad.sh  / .bat    flash LineageOS (Linux+macOS / Windows)
flash/flash_magisk.sh   / .bat    flash a re-signed Magisk boot, or --unroot
images/vbmeta-sign-disabled.img   JingPad-format vbmeta, verification off
images/vbmeta-sign-root.img       same, boot chain key = AOSP test key (Magisk)
images/vbmeta-sign-stock.img      original stock vbmeta, for restoring
images/SHA256SUMS                 checksums of the three images
tools/sign_jingpad_boot.py        re-sign a Magisk-patched boot.img
tools/make_jingpad_vbmeta.py      regenerate the vbmeta images from a stock vbmeta
tools/pac_extract.py              list / extract Unisoc .pac firmware
tools/lpdump.py                   list / extract partitions inside super.img
tools/avbtool.py                  AOSP avbtool (MIT, see tools/avbtool.LICENSE)
tools/keys/testkey_rsa4096.pem    public AOSP test signing key
prebuilt/jingpad-magisk-boot-C1-1.0.0002.014.zip
                                  Magisk v31.0 boot (signed) + stock boot, firmware 1.0.0002.014
prebuilt/SHA256SUMS               checksum of the zip
```

---

## Credits
* **Jingling** for the JingPad, its Android firmware and source release
* [MiMillieuh/JingPad-Files](https://github.com/MiMillieuh/JingPad-Files) for preserving the firmware and tools
* **deadman96385** for the [JingPad bootloader unlock tool](https://deadman96385.github.io/jingpad-unlock/subut/)
* [AndyCGYan](https://github.com/AndyCGYan/lineage_build_unified), [TrebleDroid](https://github.com/TrebleDroid) and phhusson for the LineageOS GSI recipe
* [LineageOS](https://lineageos.org)
* [topjohnwu/Magisk](https://github.com/topjohnwu/Magisk)
* AOSP for `avbtool`
