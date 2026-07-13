@echo off
setlocal
start "DevIDE" /b powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -File "%~dp0DevIDE.Tray.ps1" -ReleaseRoot "%~dp0.."
