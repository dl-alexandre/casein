[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SigningCertificateThumbprint,
    [string]$ManifestUrl = 'https://casein.devbox.milcgroup.com/downloads/windows/development/casein-development.json',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist\windows-development')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$packageRoot = Join-Path $outputDirectory 'package'
$bootstrap = Join-Path $outputDirectory 'Casein-Setup.exe'
$manifest = Join-Path $outputDirectory 'casein-development.json'

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
& (Join-Path $root 'scripts\build-windows-development-bootstrap.ps1') `
    -SigningCertificateThumbprint $SigningCertificateThumbprint `
    -ManifestUrl $ManifestUrl `
    -OutputPath $bootstrap
if ($LASTEXITCODE -ne 0) { throw 'Development bootstrap build failed.' }

$priorChannel = $env:CASEIN_RELEASE_CHANNEL
$priorManifest = $env:CASEIN_UPDATE_MANIFEST_URL
try {
    $env:CASEIN_RELEASE_CHANNEL = 'development'
    $env:CASEIN_UPDATE_MANIFEST_URL = $ManifestUrl
    & (Join-Path $root 'scripts\package-windows-desktop.ps1') `
        -OutputPath $packageRoot `
        -DevelopmentBootstrapPath $bootstrap
    if ($LASTEXITCODE -ne 0) { throw 'Windows development package build failed.' }
} finally {
    $env:CASEIN_RELEASE_CHANNEL = $priorChannel
    $env:CASEIN_UPDATE_MANIFEST_URL = $priorManifest
}

if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw "Development package did not emit its channel manifest at $manifest"
}
& (Join-Path $root 'scripts\sign-windows-development-manifest.ps1') `
    -ManifestPath $manifest `
    -SigningCertificateThumbprint $SigningCertificateThumbprint
if ($LASTEXITCODE -ne 0) { throw 'Development manifest signing failed.' }

Write-Host "Development release ready: $outputDirectory"
Write-Host 'Publish Casein-Setup.exe, casein-development.json, casein-development.json.sig, and the revisioned ZIP without renaming the ZIP.'
