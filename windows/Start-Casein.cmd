@echo off
setlocal
start "Casein" /b powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -File "%~dp0Casein.Tray.ps1" -ReleaseRoot "%~dp0.."
