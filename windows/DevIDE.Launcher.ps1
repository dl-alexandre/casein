[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\DevIDE'
$currentPath = Join-Path $installRoot 'current.json'

if (-not (Test-Path -LiteralPath $currentPath)) {
    throw 'DevIDE is not installed. Run Install-DevIDE.ps1 from a verified package first.'
}

$current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
$releaseRoot = [string]$current.release_root
$tray = Join-Path $releaseRoot 'windows\DevIDE.Tray.ps1'

if (-not $releaseRoot -or -not (Test-Path -LiteralPath $tray)) {
    throw 'The installed DevIDE release is incomplete. Run Install-DevIDE.ps1 again.'
}

Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', $tray, '-ReleaseRoot', $releaseRoot
) -WorkingDirectory $releaseRoot
