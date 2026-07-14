[CmdletBinding()]
param(
    [string]$ReleasePath,
    [string]$OutputPath,
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $ReleasePath) { $ReleasePath = Join-Path $root '_build\prod\rel\dev_ide' }
if (-not $OutputPath) { $OutputPath = Join-Path $root 'dist\DevIDE-windows-x64' }
$releasePath = [IO.Path]::GetFullPath($ReleasePath)
$outputPath = [IO.Path]::GetFullPath($OutputPath)

if ($outputPath -eq $root -or $outputPath -eq [IO.Path]::GetPathRoot($outputPath)) {
    throw "Refusing unsafe output path: $outputPath"
}

if (-not $SkipBuild) {
    $mise = Get-Command mise -ErrorAction SilentlyContinue
    $mix = Get-Command mix.bat -ErrorAction SilentlyContinue
    if (-not $mise -and -not $mix) {
        throw 'Neither mise nor mix.bat is available on PATH'
    }

    $runMix = {
        param([string[]]$MixArguments)
        if ($mise) {
            & $mise.Source exec -- mix @MixArguments
        } else {
            & $mix.Source @MixArguments
        }
        if ($LASTEXITCODE -ne 0) {
            throw "mix $($MixArguments -join ' ') failed"
        }
    }

    Push-Location $root
    try {
        $env:MIX_ENV = 'prod'
        $env:DEV_IDE_NATIVE_WINDOWS = 'true'
        $env:DEV_IDE_REPO_ADAPTER = 'sqlite'
        $env:DEVIDE_RELEASE_PROFILE = 'desktop'
        if (-not (Test-Path -LiteralPath (Join-Path $root 'assets\node_modules\@codemirror\view'))) {
            throw 'Asset dependencies are missing; run mix assets.npm before packaging'
        }
        # The colocated-assets compiler writes into assets/node_modules on Windows.
        # Force it after dependency installation so a prior compile cannot leave the
        # esbuild import missing merely because node_modules did not exist yet.
        & $runMix @('compile', '--force')
        & $runMix @('assets.deploy')
        & $runMix @('release', 'dev_ide', '--overwrite')
    } finally {
        Pop-Location
    }
}

$releaseBat = Join-Path $releasePath 'bin\dev_ide.bat'
if (-not (Test-Path -LiteralPath $releaseBat)) {
    throw "Windows release not found at $releaseBat"
}

if (Test-Path -LiteralPath $outputPath) {
    Remove-Item -Recurse -Force -LiteralPath $outputPath
}
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
Copy-Item -Recurse -Force -Path (Join-Path $releasePath '*') -Destination $outputPath
New-Item -ItemType Directory -Force -Path (Join-Path $outputPath 'windows') | Out-Null
Copy-Item -Force -LiteralPath (Join-Path $root 'windows\DevIDE.Tray.ps1') -Destination (Join-Path $outputPath 'windows')
Copy-Item -Force -LiteralPath (Join-Path $root 'windows\Start-DevIDE.cmd') -Destination (Join-Path $outputPath 'windows')
Copy-Item -Force -LiteralPath (Join-Path $root 'priv\static\images\pwa-icon-192.png') -Destination (Join-Path $outputPath 'windows\DevIDE.png')

Write-Host "Packaged DevIDE Windows desktop runtime: $outputPath"
Write-Host "Launch: $outputPath\windows\Start-DevIDE.cmd"
