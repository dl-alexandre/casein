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

function ConvertTo-CaseinUtcTimestamp {
    param([object]$Value, [switch]$AllowNull)

    if ($null -eq $Value -or -not [string]$Value) {
        if ($AllowNull) { return $null }
        throw 'A required timestamp is missing.'
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )) {
        throw 'A diagnostic timestamp is invalid.'
    }
    $parsed.ToUniversalTime().ToString('o')
}

function Test-CaseinDiagnosticToken {
    param([string]$Value, [int]$MaximumLength = 64)

    return $Value.Length -ge 1 -and $Value.Length -le $MaximumLength -and
        $Value -match '^[A-Za-z0-9][A-Za-z0-9._+\-]*$'
}

function Write-CaseinInvalidStateMarker {
    param([string]$Name, [string]$Message)

    Set-Content -LiteralPath (Join-Path $stage "$Name-invalid.txt") -Value $Message -Encoding ascii
}

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

    $logPath = Join-Path $DataRoot 'desktop-host.log'
    if (Test-Path -LiteralPath $logPath) { Copy-Item -LiteralPath $logPath -Destination $stage -Force }

    $settingsPath = Join-Path $DataRoot 'desktop-host.json'
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
            $port = [int]$settings.port
            if ($port -lt 0 -or $port -gt 65535) { throw 'Invalid desktop port.' }
            if ($settings.launchAtSignIn -isnot [bool]) { throw 'Invalid launch-at-sign-in state.' }
            [ordered]@{
                port = $port
                launchAtSignIn = [bool]$settings.launchAtSignIn
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'desktop-host.json') -Encoding UTF8
        } catch {
            Write-CaseinInvalidStateMarker 'desktop-host' 'Desktop host settings were invalid.'
        }
    }

    $runtimePath = Join-Path $DataRoot 'runtime.json'
    if (Test-Path -LiteralPath $runtimePath) {
        try {
            $runtime = Get-Content -Raw -LiteralPath $runtimePath | ConvertFrom-Json
            $port = [int]$runtime.port
            $runtimePid = [int]$runtime.pid
            $version = [string]$runtime.version
            $revision = [string]$runtime.revision
            if ([int]$runtime.schema -ne 1 -or [string]$runtime.status -ne 'ready') { throw 'Invalid runtime schema or status.' }
            if ($port -lt 1 -or $port -gt 65535 -or $runtimePid -lt 1) { throw 'Invalid runtime process identity.' }
            if ([string]$runtime.base_url -ne "http://127.0.0.1:$port") { throw 'Invalid runtime base URL.' }
            if (-not (Test-CaseinDiagnosticToken $version)) { throw 'Invalid runtime version.' }
            if ($revision -ne 'unknown' -and $revision -notmatch '^[0-9a-fA-F]{7,64}$') { throw 'Invalid runtime revision.' }
            [ordered]@{
                schema = 1
                status = 'ready'
                port = $port
                base_url = "http://127.0.0.1:$port"
                pid = $runtimePid
                version = $version
                revision = $revision
                started_at = ConvertTo-CaseinUtcTimestamp $runtime.started_at
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'runtime.json') -Encoding UTF8
        } catch {
            Write-CaseinInvalidStateMarker 'runtime' 'Desktop runtime state was invalid.'
        }
    }

    $trustedLanPath = Join-Path $DataRoot 'trusted-lan.json'
    if (Test-Path -LiteralPath $trustedLanPath) {
        try {
            $trustedLan = Get-Content -Raw -LiteralPath $trustedLanPath | ConvertFrom-Json
            if ([int]$trustedLan.schema -ne 1) { throw 'Invalid Trusted LAN schema.' }
            if ($trustedLan.enabled -isnot [bool]) { throw 'Invalid Trusted LAN enabled state.' }
            $enabled = [bool]$trustedLan.enabled
            if ($enabled) {
                $address = $null
                if (-not [Net.IPAddress]::TryParse([string]$trustedLan.address, [ref]$address)) { throw 'Invalid Trusted LAN address.' }
                $bytes = $address.GetAddressBytes()
                $private = $bytes.Length -eq 4 -and ($bytes[0] -eq 10 -or
                    ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
                    ($bytes[0] -eq 192 -and $bytes[1] -eq 168))
                $port = [int]$trustedLan.port
                $interfaceIndex = [int]$trustedLan.interface_index
                $alias = [string]$trustedLan.interface_alias
                if (-not $private -or $port -lt 1024 -or $port -gt 65535 -or $interfaceIndex -lt 0) { throw 'Invalid Trusted LAN endpoint.' }
                if ($alias.Length -lt 1 -or $alias.Length -gt 128 -or $alias -match '[\x00-\x1F]') { throw 'Invalid Trusted LAN interface.' }
                [ordered]@{
                    schema = 1
                    enabled = $true
                    address = $address.ToString()
                    interface_alias = $alias
                    interface_index = $interfaceIndex
                    port = $port
                    url = "http://$($address.ToString()):$port"
                    enabled_at_utc = ConvertTo-CaseinUtcTimestamp $trustedLan.enabled_at_utc
                } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'trusted-lan.json') -Encoding UTF8
            } else {
                [ordered]@{
                    schema = 1
                    enabled = $false
                    disabled_at_utc = ConvertTo-CaseinUtcTimestamp $trustedLan.disabled_at_utc
                } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'trusted-lan.json') -Encoding UTF8
            }
        } catch {
            Write-CaseinInvalidStateMarker 'trusted-lan' 'Trusted LAN state was invalid.'
        }
    }
    $credentialStatePath = Join-Path $DataRoot 'credential-state.json'
    if (Test-Path -LiteralPath $credentialStatePath) {
        try {
            $credentialState = Get-Content -Raw -LiteralPath $credentialStatePath | ConvertFrom-Json
            if ([int]$credentialState.schema -ne 1) { throw 'Invalid credential state schema.' }
            [ordered]@{
                schema = 1
                rotated_at_utc = ConvertTo-CaseinUtcTimestamp $credentialState.rotated_at_utc
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'credential-state.json') -Encoding UTF8
        } catch {
            Set-Content -LiteralPath (Join-Path $stage 'credential-state-invalid.txt') -Value 'Credential rotation state was invalid.' -Encoding ascii
        }
    }
    $crashStatePath = Join-Path $DataRoot 'crash-state.json'
    if (Test-Path -LiteralPath $crashStatePath) {
        try {
            $crashState = Get-Content -Raw -LiteralPath $crashStatePath | ConvertFrom-Json
            if ([int]$crashState.schema -ne 1) { throw 'Unsupported crash state schema.' }
            $allowedStatuses = @('detected', 'recovering', 'recovered', 'exhausted', 'startup_failed')
            if ($allowedStatuses -notcontains [string]$crashState.recovery_status) { throw 'Invalid recovery status.' }
            $detectedAt = ConvertTo-CaseinUtcTimestamp $crashState.detected_at_utc
            $recoveredAt = ConvertTo-CaseinUtcTimestamp $crashState.recovered_at_utc -AllowNull
            $exitCode = $null
            if ($null -ne $crashState.exit_code) { $exitCode = [int]$crashState.exit_code }
            [ordered]@{
                schema = 1
                detected_at_utc = $detectedAt
                runtime_pid = [Math]::Max(0, [int]$crashState.runtime_pid)
                exit_code = $exitCode
                recovery_attempts = [Math]::Min(3, [Math]::Max(0, [int]$crashState.recovery_attempts))
                recovery_status = [string]$crashState.recovery_status
                recovered_at_utc = $recoveredAt
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'crash-state.json') -Encoding UTF8
        } catch {
            Set-Content -LiteralPath (Join-Path $stage 'crash-state-invalid.txt') -Value 'Crash recovery state was invalid.' -Encoding ascii
        }
    }
    $currentPath = Join-Path $InstallRoot 'current.json'
    if (Test-Path -LiteralPath $currentPath) {
        try {
            $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
            $version = [string]$current.version
            $revision = [string]$current.revision
            $thumbprint = [string]$current.signer_thumbprint
            if ([int]$current.schema -ne 1 -or -not (Test-CaseinDiagnosticToken $version)) { throw 'Invalid installed release identity.' }
            if ($revision -notmatch '^[0-9a-fA-F]{7,64}$') { throw 'Invalid installed revision.' }
            if ($thumbprint -and $thumbprint -notmatch '^[0-9a-fA-F]{40,128}$') { throw 'Invalid signer thumbprint.' }
            [ordered]@{
                schema = 1
                version = $version
                revision = $revision
                signer_thumbprint = if ($thumbprint) { $thumbprint.ToUpperInvariant() } else { $null }
                installed_at_utc = ConvertTo-CaseinUtcTimestamp $current.installed_at_utc
                has_previous_release = [bool]([string]$current.previous_release_root)
                has_previous_data_backup = [bool]([string]$current.previous_data_backup)
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'current.json') -Encoding UTF8
        } catch {
            Write-CaseinInvalidStateMarker 'current' 'Installed release state was invalid.'
        }
    }

    # Credentials are intentionally excluded: api-token, launch-token,
    # secret-key-base, and any SQLite/user workspace content never enter this bundle.
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Destination -CompressionLevel Optimal
    Write-Output $Destination
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
