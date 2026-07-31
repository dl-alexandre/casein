[CmdletBinding()]
param(
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'Casein'),
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Casein'),
    [string]$Destination = (Join-Path ([Environment]::GetFolderPath('Desktop')) ("Casein-support-{0}.zip" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stage = Join-Path $env:TEMP ("Casein-support-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage | Out-Null

try {
    $summary = [ordered]@{
        schema = 1
        created_at_utc = [DateTime]::UtcNow.ToString('o')
        os = [Environment]::OSVersion.VersionString
        os_architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        process_architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        powershell = $PSVersionTable.PSVersion.ToString()
        user_interactive = [Environment]::UserInteractive
    }
    $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'system.json') -Encoding UTF8

    foreach ($name in @('desktop-host.log', 'runtime.json', 'desktop-host.json', 'trusted-lan.json')) {
        $source = Join-Path $DataRoot $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $stage -Force }
    }
    $credentialStatePath = Join-Path $DataRoot 'credential-state.json'
    if (Test-Path -LiteralPath $credentialStatePath) {
        try {
            $credentialState = Get-Content -Raw -LiteralPath $credentialStatePath | ConvertFrom-Json
            [ordered]@{
                schema = [int]$credentialState.schema
                rotated_at_utc = [string]$credentialState.rotated_at_utc
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'credential-state.json') -Encoding UTF8
        } catch {
            Set-Content -LiteralPath (Join-Path $stage 'credential-state-invalid.txt') -Value 'Credential rotation state was invalid.' -Encoding ascii
        }
    }
    foreach ($name in @('current.json')) {
        $source = Join-Path $InstallRoot $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $stage -Force }
    }

    # Credentials are intentionally excluded: api-token, launch-token,
    # secret-key-base, and any SQLite/user workspace content never enter this bundle.
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Destination -CompressionLevel Optimal
    Write-Output $Destination
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
