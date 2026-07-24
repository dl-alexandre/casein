[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Casein'),
    [switch]$Launch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$currentPath = Join-Path $InstallRoot 'current.json'
if (-not (Test-Path -LiteralPath $currentPath)) { throw 'Casein is not installed.' }
$current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
$releaseRoot = [IO.Path]::GetFullPath([string]$current.release_root)
$releasesRoot = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'releases'))
if (-not $releaseRoot.StartsWith($releasesRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installed release path is outside the Casein releases directory.'
}
$release = Join-Path $releaseRoot 'bin\casein.bat'
if (-not (Test-Path -LiteralPath $release)) { throw "Installed runtime is missing: $release" }

$dataRoot = Join-Path $env:LOCALAPPDATA 'Casein'
$pidPath = Join-Path $dataRoot 'runtime.pid'
if (Test-Path -LiteralPath $pidPath) {
    $runtimePid = 0
    [void][int]::TryParse((Get-Content -Raw -LiteralPath $pidPath).Trim(), [ref]$runtimePid)
    if ($runtimePid -gt 0 -and (Get-Process -Id $runtimePid -ErrorAction SilentlyContinue)) {
        & taskkill.exe /PID $runtimePid /T /F *> $null
    }
}
Remove-Item -LiteralPath $pidPath, (Join-Path $dataRoot 'runtime.json') -Force -ErrorAction SilentlyContinue

$env:CASEIN_PROFILE = 'desktop'
$env:CASEIN_REPO_ADAPTER = 'sqlite'
$env:CASEIN_DESKTOP_DATA_DIR = $dataRoot
$env:DEVIDE_RELEASE_ROOT = $releaseRoot
& $release migrate
if ($LASTEXITCODE -ne 0) { throw "Casein database repair failed with exit code $LASTEXITCODE" }

if ($Launch) {
    & (Join-Path $InstallRoot 'Casein.Launcher.ps1')
}
Write-Host 'Casein installation repair completed.'
