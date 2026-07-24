[CmdletBinding()]
param(
    [ValidateSet('Status', 'Enable', 'Disable')]
    [string]$Action = 'Status',
    [int]$Port = 0,
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'Casein'),
    [string]$ReleaseRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FirewallGroup = 'Casein Trusted LAN'
$script:FirewallRuleName = 'Casein Trusted LAN (private network)'
$script:StatePath = Join-Path $DataRoot 'trusted-lan.json'

function Test-CaseinAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CaseinPrivateIPv4 {
    param([string]$Address)

    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $false }
    return $bytes[0] -eq 10 -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
}

function Get-CaseinLanCandidates {
    $metrics = @{}
    foreach ($entry in @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop)) {
        $metrics[[int]$entry.InterfaceIndex] = [int]$entry.InterfaceMetric
    }

    foreach ($configuration in @(Get-NetIPConfiguration -Detailed -ErrorAction Stop)) {
        $adapter = $configuration.NetAdapter
        $profile = $configuration.NetProfile
        if ($null -eq $adapter -or $adapter.Status -ne 'Up') { continue }
        if ($null -eq $profile -or [string]$profile.NetworkCategory -ne 'Private') { continue }

        $alias = [string]$configuration.InterfaceAlias
        $description = [string]$configuration.InterfaceDescription
        $virtualOrTunnel = "$alias $description" -match '(?i)\b(vpn|wireguard|tailscale|tunnel|tap|tun|hyper-v|vethernet|wsl|loopback|virtualbox|vmware)\b'

        foreach ($ip in @($configuration.IPv4Address)) {
            $address = [string]$ip.IPAddress
            if (-not (Test-CaseinPrivateIPv4 $address)) { continue }
            [pscustomobject]@{
                Address = $address
                InterfaceAlias = $alias
                InterfaceDescription = $description
                InterfaceIndex = [int]$configuration.InterfaceIndex
                InterfaceMetric = if ($metrics.ContainsKey([int]$configuration.InterfaceIndex)) {
                    $metrics[[int]$configuration.InterfaceIndex]
                } else {
                    [int]::MaxValue
                }
                HasDefaultGateway = @($configuration.IPv4DefaultGateway).Count -gt 0
                VirtualOrTunnel = $virtualOrTunnel
            }
        }
    }
}

function Select-CaseinLanAddress {
    param([object[]]$Candidates = @())

    $eligible = @($Candidates | Where-Object { -not $_.VirtualOrTunnel })
    if ($eligible.Count -eq 0) {
        throw 'No eligible private Wi-Fi or Ethernet address is available. VPN, Hyper-V, WSL, tunnel, virtual, public, and loopback interfaces are not exposed automatically.'
    }

    $eligible |
        Sort-Object `
            @{ Expression = { if ($_.HasDefaultGateway) { 0 } else { 1 } } }, `
            @{ Expression = { [int]$_.InterfaceMetric } }, `
            @{ Expression = { [int]$_.InterfaceIndex } }, `
            @{ Expression = { [string]$_.Address } } |
        Select-Object -First 1
}

function Read-CaseinTrustedLanState {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return [pscustomobject]@{ enabled = $false }
    }
    try {
        Get-Content -Raw -LiteralPath $script:StatePath | ConvertFrom-Json
    } catch {
        [pscustomobject]@{ enabled = $false; error = 'The saved Trusted LAN state is invalid.' }
    }
}

function Write-CaseinTrustedLanState {
    param([object]$State)

    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    $temporary = "$($script:StatePath).$PID.tmp"
    $State | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $script:StatePath -Force
}

function Remove-CaseinTrustedLanFirewallRules {
    if (-not (Test-CaseinAdministrator)) {
        throw 'Administrator consent is required to remove the Casein Trusted LAN firewall rule.'
    }
    Get-NetFirewallRule -Group $script:FirewallGroup -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction Stop
}

function Enable-CaseinTrustedLan {
    param([int]$ListenPort)

    if ($ListenPort -lt 1024 -or $ListenPort -gt 65535) {
        throw 'Trusted LAN requires the current Casein desktop port (1024-65535).'
    }
    if (-not (Test-CaseinAdministrator)) {
        throw 'Administrator consent is required to create the Casein Trusted LAN firewall rule.'
    }

    $selected = Select-CaseinLanAddress @(Get-CaseinLanCandidates)
    $releasePath = [IO.Path]::GetFullPath($ReleaseRoot).TrimEnd('\') + '\'
    $program = Get-ChildItem -LiteralPath $ReleaseRoot -Directory -Filter 'erts-*' |
        ForEach-Object { Join-Path $_.FullName 'bin\erl.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $program -or -not ([IO.Path]::GetFullPath($program)).StartsWith($releasePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The packaged Erlang runtime executable could not be resolved safely.'
    }
    Remove-CaseinTrustedLanFirewallRules
    New-NetFirewallRule `
        -DisplayName $script:FirewallRuleName `
        -Group $script:FirewallGroup `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Profile Private `
        -Protocol TCP `
        -Program $program `
        -LocalPort $ListenPort `
        -LocalAddress $selected.Address `
        -RemoteAddress LocalSubnet `
        -Description 'Casein mobile pairing on the selected trusted private LAN only.' |
        Out-Null

    $state = [ordered]@{
        schema = 1
        enabled = $true
        address = $selected.Address
        interface_alias = $selected.InterfaceAlias
        interface_index = $selected.InterfaceIndex
        port = $ListenPort
        program = $program
        url = "http://$($selected.Address):$ListenPort"
        enabled_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    Write-CaseinTrustedLanState $state
    [pscustomobject]$state
}

function Disable-CaseinTrustedLan {
    Remove-CaseinTrustedLanFirewallRules
    Write-CaseinTrustedLanState ([ordered]@{
        schema = 1
        enabled = $false
        disabled_at_utc = [DateTime]::UtcNow.ToString('o')
    })
}

if (-not $LibraryOnly) {
    switch ($Action) {
        'Status' { Read-CaseinTrustedLanState | ConvertTo-Json }
        'Enable' { Enable-CaseinTrustedLan $Port | ConvertTo-Json }
        'Disable' { Disable-CaseinTrustedLan }
    }
}
