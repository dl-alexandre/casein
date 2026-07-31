@echo off
setlocal
rem Re-running the signed offline installer validates and rehydrates the installed release.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\Install-Casein.ps1" -PackageRoot "%~dp0" -RequireSigned -Launch
exit /b %ERRORLEVEL%
