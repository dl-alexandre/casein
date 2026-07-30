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
$previousProperty = $current.PSObject.Properties['previous_release_root']
$previous = if ($previousProperty) { [string]$previousProperty.Value } else { $null }
if (-not $previous) { throw 'No previous Casein release is available.' }
$previous = [IO.Path]::GetFullPath($previous)
$releasesRoot = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'releases')).TrimEnd('\') + '\'
if (-not $previous.StartsWith($releasesRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Previous release path is outside the Casein releases directory.'
}
$metadataPath = Join-Path $previous 'releases\casein.relmeta.json'
if (-not (Test-Path -LiteralPath $metadataPath)) { throw 'Previous release is incomplete.' }
$metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json

$backupProperty = $current.PSObject.Properties['previous_data_backup']
$backup = if ($backupProperty) { [string]$backupProperty.Value } else { $null }
if ($backup) {
    . (Join-Path $InstallRoot 'Casein.Backup.ps1') -LibraryOnly
    $dataRoot = Join-Path $env:LOCALAPPDATA 'Casein'
    New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
    foreach ($name in @('casein.sqlite3', 'casein.sqlite3-wal', 'casein.sqlite3-shm')) {
        $encryptedDatabase = Join-Path $backup "$name.dpapi"
        $backupManifest = Join-Path $backup "$name.backup.json"
        if ((Test-Path -LiteralPath $encryptedDatabase) -or (Test-Path -LiteralPath $backupManifest)) {
            if (-not ((Test-Path -LiteralPath $encryptedDatabase) -and (Test-Path -LiteralPath $backupManifest))) {
                throw "The previous $name backup is incomplete; rollback was not changed."
            }
            Restore-CaseinBackupFile -Source $encryptedDatabase -Manifest $backupManifest -Destination (Join-Path $dataRoot $name)
        }
    }
}
$next = [ordered]@{
    schema = 1
    version = $metadata.version
    revision = $metadata.revision
    release_root = $previous
    previous_release_root = [string]$current.release_root
    previous_data_backup = $backup
    signer_thumbprint = if ($current.PSObject.Properties['signer_thumbprint']) { [string]$current.signer_thumbprint } else { $null }
    installed_at_utc = [DateTime]::UtcNow.ToString('o')
    rollback = $true
} | ConvertTo-Json
$temporary = "$currentPath.$PID.tmp"
Set-Content -LiteralPath $temporary -Value $next -Encoding UTF8
Move-Item -LiteralPath $temporary -Destination $currentPath -Force

if ($Launch) { & (Join-Path $InstallRoot 'Casein.Launcher.ps1') }
Write-Host "Rolled Casein back to $($metadata.version)-$($metadata.revision.Substring(0, 7))."
