[CmdletBinding()]
param(
    [string]$NodePath,
    [string]$NpmPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scripts = Join-Path $root 'priv\scripts'

if (-not $NodePath) {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($node) { $NodePath = $node.Source }
}
if (-not $NpmPath) {
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($npm) { $NpmPath = $npm.Source }
}
if (-not $NodePath -or -not (Test-Path -LiteralPath $NodePath)) {
    throw 'node.exe is required. Pass -NodePath when Node is not on PATH.'
}
if (-not $NpmPath -or -not (Test-Path -LiteralPath $NpmPath)) {
    throw 'npm.cmd is required. Pass -NpmPath when npm is not on PATH.'
}

$runtime = Join-Path $scripts 'runtime'
$browsers = Join-Path $scripts 'playwright-browsers'
New-Item -ItemType Directory -Force -Path $runtime, $browsers | Out-Null
Copy-Item -Force -LiteralPath $NodePath -Destination (Join-Path $runtime 'node.exe')

Push-Location $scripts
try {
    & $NpmPath ci --omit=dev --no-audit --no-fund --no-progress
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed for the preview runtime' }
    # #929: install stays --no-audit; scan the lockfile before using the tree.
    & $NpmPath audit --package-lock-only --audit-level=high
    if ($LASTEXITCODE -ne 0) { throw 'npm audit failed for the preview runtime' }

    $env:PLAYWRIGHT_BROWSERS_PATH = $browsers
    & (Join-Path $runtime 'node.exe') (Join-Path $scripts 'node_modules\playwright\cli.js') install chromium
    if ($LASTEXITCODE -ne 0) { throw 'Playwright Chromium installation failed' }
} finally {
    Pop-Location
}

Write-Host "Prepared self-contained preview runtime: $scripts"
