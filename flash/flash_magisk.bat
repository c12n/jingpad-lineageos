@echo off
rem Root a JingPad A1/C1 with Magisk (Windows).
rem usage: flash_magisk.bat boot-magisk-signed.img
rem        flash_magisk.bat --unroot boot-stock.img
rem The image must already be re-signed with tools\sign_jingpad_boot.py.
rem Tablet in bootloader fastboot mode first: adb reboot bootloader
setlocal
set "KIT=%~dp0.."
set "VBMETA=%KIT%\images\vbmeta-sign-root.img"
set "MODE=root"
if /i "%~1"=="--unroot" (set "VBMETA=%KIT%\images\vbmeta-sign-disabled.img" & set "MODE=unroot" & shift)
set "IMG=%~1"
if "%IMG%"=="" (echo usage: %~nx0 [--unroot] ^<boot image^> & exit /b 1)
if not exist "%IMG%" (echo File not found: %IMG% & exit /b 1)

rem avbtool hashes PARTITION.img from the same folder, so check a copy named boot.img
if "%MODE%"=="root" where python >nul 2>&1 && (
  if not exist "%TEMP%\jp-verify" mkdir "%TEMP%\jp-verify"
  copy /y "%IMG%" "%TEMP%\jp-verify\boot.img" >nul
  python "%KIT%\tools\avbtool.py" verify_image --image "%TEMP%\jp-verify\boot.img" > "%TEMP%\jp-verify\log.txt" 2>&1 || (
    echo %IMG% is not signed. Run: python tools\sign_jingpad_boot.py magisk_patched.img boot-magisk-signed.img
    exit /b 1
  )
)

if exist "%IMG%.fingerprint" (
  echo This prebuilt boot is only for the tablet build in %IMG%.fingerprint:
  type "%IMG%.fingerprint"
  echo Check yours with: adb shell getprop ro.bootimage.build.fingerprint
  set /p OK=Type YES if they match:
)
if exist "%IMG%.fingerprint" if not "%OK%"=="YES" (echo Aborted. & exit /b 1)

fastboot getvar is-userspace 2>&1 | find "is-userspace: yes" >nul && (
  echo Tablet is in fastbootd. Run "fastboot reboot bootloader" and retry.
  exit /b 1
)
echo Flashing vbmeta and boot...
fastboot flash vbmeta "%VBMETA%" || exit /b 1
fastboot flash boot "%IMG%" || exit /b 1
fastboot reboot
echo.
echo Done. Open the Magisk app once Android is up.
echo Never use Magisk "Direct Install" for updates: patch a file, re-sign, flash.
exit /b 0
