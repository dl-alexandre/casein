[CmdletBinding()]
param([switch]$LibraryOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Protect-CaseinBackupFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.Security
    $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Source))
    $hash = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        [Text.Encoding]::UTF8.GetBytes('Casein Windows backup v1'),
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [IO.File]::WriteAllBytes([IO.Path]::GetFullPath($Destination), $protected)
    [ordered]@{
        schema = 1
        protection = 'dpapi-current-user'
        source_bytes = $bytes.LongLength
        sha256 = $hash
        created_at_utc = [DateTime]::UtcNow.ToString('o')
    }
}

function Restore-CaseinBackupFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Manifest,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.Security
    $metadata = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json
    if ($metadata.schema -ne 1 -or $metadata.protection -ne 'dpapi-current-user') {
        throw 'Casein backup metadata is unsupported.'
    }
    $protected = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Source))
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        [Text.Encoding]::UTF8.GetBytes('Casein Windows backup v1'),
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $hash = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    if ($hash -ne [string]$metadata.sha256 -or $bytes.LongLength -ne [long]$metadata.source_bytes) {
        throw 'Casein backup failed its size or SHA-256 validation.'
    }
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    $temporary = "$destinationPath.$PID.restore"
    [IO.File]::WriteAllBytes($temporary, $bytes)
    Move-Item -LiteralPath $temporary -Destination $destinationPath -Force
}

if (-not $LibraryOnly) {
    throw 'Casein.Backup.ps1 is a library and cannot be run directly.'
}
