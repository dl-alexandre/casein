[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\DevIDE'),
    [switch]$Launch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$currentPath = Join-Path $InstallRoot 'current.json'
if (-not (Test-Path -LiteralPath $currentPath)) { throw 'DevIDE is not installed.' }
$current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
$previousProperty = $current.PSObject.Properties['previous_release_root']
$previous = if ($previousProperty) { [string]$previousProperty.Value } else { $null }
if (-not $previous) { throw 'No previous DevIDE release is available.' }
$previous = [IO.Path]::GetFullPath($previous)
$releasesRoot = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'releases')).TrimEnd('\') + '\'
if (-not $previous.StartsWith($releasesRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Previous release path is outside the DevIDE releases directory.'
}
$metadataPath = Join-Path $previous 'releases\dev_ide.relmeta.json'
if (-not (Test-Path -LiteralPath $metadataPath)) { throw 'Previous release is incomplete.' }
$metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json

$backupProperty = $current.PSObject.Properties['previous_data_backup']
$next = [ordered]@{
    schema = 1
    version = $metadata.version
    revision = $metadata.revision
    release_root = $previous
    previous_release_root = [string]$current.release_root
    previous_data_backup = if ($backupProperty) { [string]$backupProperty.Value } else { $null }
    installed_at_utc = [DateTime]::UtcNow.ToString('o')
    rollback = $true
} | ConvertTo-Json
$temporary = "$currentPath.$PID.tmp"
Set-Content -LiteralPath $temporary -Value $next -Encoding UTF8
Move-Item -LiteralPath $temporary -Destination $currentPath -Force

if ($Launch) { & (Join-Path $InstallRoot 'DevIDE.Launcher.ps1') }
Write-Host "Rolled Casein back to $($metadata.version)-$($metadata.revision.Substring(0, 7))."
