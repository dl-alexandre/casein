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

function Test-CaseinPreviewRuntime {
    param([string]$Root)

    $scripts = Get-ChildItem -LiteralPath (Join-Path $Root 'lib') -Directory |
        ForEach-Object { Join-Path $_.FullName 'priv\scripts' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'preview_playwright.mjs') } |
        Select-Object -First 1
    if (-not $scripts) {
        throw 'Windows preview runtime is missing its Playwright helper. Reinstall Casein from a verified package or roll back to the previous release.'
    }

    $node = Join-Path $scripts 'runtime\node.exe'
    $helper = Join-Path $scripts 'preview_playwright.mjs'
    $browsers = Join-Path $scripts 'playwright-browsers'
    foreach ($required in @($node, $helper, $browsers)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "Windows preview runtime is incomplete at $required. Reinstall Casein from a verified package or roll back to the previous release."
        }
    }

    $previousBrowsersPath = $env:PLAYWRIGHT_BROWSERS_PATH
    try {
        $env:PLAYWRIGHT_BROWSERS_PATH = $browsers
        $output = @(& $node $helper '{"action":"diagnose"}' 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Windows preview diagnostic exited with code $LASTEXITCODE`: $($output -join [Environment]::NewLine)"
        }

        try {
            $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json
        } catch {
            throw "Windows preview diagnostic returned invalid output: $($output -join [Environment]::NewLine)"
        }

        if (-not $result.ok -or $result.diagnostic.status -ne 'ready') {
            $reason = if ($result.error) { [string]$result.error } else { 'unknown diagnostic failure' }
            throw "Windows preview runtime is not usable: $reason"
        }

        Write-Host "Windows preview runtime ready: $($result.diagnostic.chromium_executable)"
    } finally {
        $env:PLAYWRIGHT_BROWSERS_PATH = $previousBrowsersPath
    }
}

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

Test-CaseinPreviewRuntime $releaseRoot

$env:CASEIN_PROFILE = 'desktop'
$env:CASEIN_REPO_ADAPTER = 'sqlite'
$env:CASEIN_DESKTOP_DATA_DIR = $dataRoot
$env:CASEIN_RELEASE_ROOT = $releaseRoot
& $release migrate
if ($LASTEXITCODE -ne 0) { throw "Casein database repair failed with exit code $LASTEXITCODE" }

if ($Launch) {
    & (Join-Path $InstallRoot 'Casein.Launcher.ps1')
}
Write-Host 'Casein installation repair completed.'
