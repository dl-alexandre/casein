[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'This smoke requires Windows PowerShell 5.1.' }

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $env:TEMP ('casein-support-bundle-' + [Guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $testRoot 'data'
$installRoot = Join-Path $testRoot 'install'
$archive = Join-Path $testRoot 'support.zip'
$expanded = Join-Path $testRoot 'expanded'
$secret = 'must-not-ship'
New-Item -ItemType Directory -Path $dataRoot, $installRoot | Out-Null

try {
    [ordered]@{
        port = 4567
        launchAtSignIn = $true
        injected_secret = $secret
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataRoot 'desktop-host.json') -Encoding UTF8
    [ordered]@{
        schema = 1
        status = 'ready'
        port = 4567
        base_url = 'http://127.0.0.1:4567'
        pid = 4242
        version = '0.1.0'
        revision = 'abcdef1234567890'
        started_at = [DateTime]::UtcNow.ToString('o')
        injected_secret = $secret
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataRoot 'runtime.json') -Encoding UTF8
    [ordered]@{
        schema = 1
        enabled = $true
        address = '192.168.1.20'
        interface_alias = 'Ethernet'
        interface_index = 3
        port = 4567
        program = "C:\$secret\erl.exe"
        url = "http://$secret"
        enabled_at_utc = [DateTime]::UtcNow.ToString('o')
        injected_secret = $secret
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataRoot 'trusted-lan.json') -Encoding UTF8
    [ordered]@{
        schema = 1
        version = '0.1.0'
        revision = 'abcdef1234567890'
        release_root = "C:\$secret\release"
        previous_release_root = 'C:\previous\release'
        previous_data_backup = 'C:\backup\snapshot.json'
        signer_thumbprint = '0123456789ABCDEF0123456789ABCDEF01234567'
        installed_at_utc = [DateTime]::UtcNow.ToString('o')
        injected_secret = $secret
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installRoot 'current.json') -Encoding UTF8

    & (Join-Path $root 'windows\New-CaseinSupportBundle.ps1') `
        -DataRoot $dataRoot -InstallRoot $installRoot -Destination $archive | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded

    foreach ($name in @('desktop-host.json', 'runtime.json', 'trusted-lan.json', 'current.json')) {
        $text = Get-Content -Raw -LiteralPath (Join-Path $expanded $name)
        if ($text.Contains($secret)) { throw "$name copied an untrusted field or path." }
    }
    $current = Get-Content -Raw -LiteralPath (Join-Path $expanded 'current.json') | ConvertFrom-Json
    if (-not $current.has_previous_release -or -not $current.has_previous_data_backup) {
        throw 'Install rollback availability was not retained.'
    }
    $trustedLan = Get-Content -Raw -LiteralPath (Join-Path $expanded 'trusted-lan.json') | ConvertFrom-Json
    if ($trustedLan.url -ne 'http://192.168.1.20:4567') { throw 'Trusted LAN URL was not reconstructed.' }

    Set-Content -LiteralPath (Join-Path $dataRoot 'runtime.json') -Value '{"schema":999}' -Encoding ascii
    $invalidArchive = Join-Path $testRoot 'invalid.zip'
    $invalidExpanded = Join-Path $testRoot 'invalid-expanded'
    & (Join-Path $root 'windows\New-CaseinSupportBundle.ps1') `
        -DataRoot $dataRoot -InstallRoot $installRoot -Destination $invalidArchive | Out-Null
    Expand-Archive -LiteralPath $invalidArchive -DestinationPath $invalidExpanded
    if (-not (Test-Path -LiteralPath (Join-Path $invalidExpanded 'runtime-invalid.txt'))) {
        throw 'Invalid runtime state was not replaced with a safe marker.'
    }
    if (Test-Path -LiteralPath (Join-Path $invalidExpanded 'runtime.json')) {
        throw 'Invalid runtime state entered the support bundle.'
    }

    [ordered]@{ port = 4567; launchAtSignIn = 'true' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataRoot 'desktop-host.json') -Encoding UTF8
    $invalidTypeArchive = Join-Path $testRoot 'invalid-type.zip'
    $invalidTypeExpanded = Join-Path $testRoot 'invalid-type-expanded'
    & (Join-Path $root 'windows\New-CaseinSupportBundle.ps1') `
        -DataRoot $dataRoot -InstallRoot $installRoot -Destination $invalidTypeArchive | Out-Null
    Expand-Archive -LiteralPath $invalidTypeArchive -DestinationPath $invalidTypeExpanded
    if (-not (Test-Path -LiteralPath (Join-Path $invalidTypeExpanded 'desktop-host-invalid.txt'))) {
        throw 'A non-boolean desktop setting was not replaced with a safe marker.'
    }

    Write-Host 'Windows support-bundle JSON allowlist smoke passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
