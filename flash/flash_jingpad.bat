@echo off
rem Flash a LineageOS GSI onto a JingPad A1/C1 running the stock Android 10 ROM (Windows).
rem usage: flash_jingpad.bat lineage-20.0-...-arm64_bvN.img
rem Needs platform-tools (fastboot.exe) on PATH or in this folder, bootloader unlocked,
rem and the tablet in bootloader fastboot mode (adb reboot bootloader).
setlocal
set "KIT=%~dp0.."
set "IMG=%~1"
if "%IMG%"=="" (echo usage: %~nx0 ^<lineage system .img^> & exit /b 1)
if not exist "%IMG%" (echo File not found: %IMG% & exit /b 1)
if /i "%IMG:~-3%"==".xz" (echo Decompress the .xz first, e.g. with 7-Zip. & exit /b 1)

echo.
echo This flashes a verification-disabled vbmeta, replaces Android with
echo %IMG%
echo and needs a factory reset. ALL DATA ON THE TABLET WILL BE ERASED.
echo Keep the stock .pac and JingPad Flash Tool handy to restore.
set /p OK=Type YES to continue:
if not "%OK%"=="YES" (echo Aborted. & exit /b 1)

echo.
echo [1/4] Flashing vbmeta (verification disabled, Unisoc DHTB format)
fastboot flash vbmeta "%KIT%\images\vbmeta-sign-disabled.img" || goto :fail

echo.
echo [2/4] Rebooting into fastbootd
fastboot reboot fastboot
echo If the tablet shows the recovery menu instead of "fastbootd",
echo choose "Enter fastboot" with the volume keys and Power.
pause
fastboot getvar is-userspace 2>&1 | find "is-userspace: yes" >nul || (echo Not in fastbootd yet. & goto :fail)

echo.
echo [3/4] Flashing LineageOS into super/system (product is kept on purpose)
fastboot flash system "%IMG%" || goto :fail

echo.
echo [4/4] Rebooting to recovery
fastboot reboot recovery
echo.
echo On the tablet: "Wipe data/factory reset", then "Reboot system now".
echo First boot can take 5-10 minutes.
exit /b 0

:fail
echo.
echo Flashing stopped. To undo the vbmeta change, in bootloader fastboot mode run:
echo   fastboot flash vbmeta "%KIT%\images\vbmeta-sign-stock.img"
exit /b 1
