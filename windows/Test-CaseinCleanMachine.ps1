[CmdletBinding()]
param(
    [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory = $true)]
    [switch]$AcceptDestructiveCleanMachineTest,
    [switch]$RequireNoDeveloperTooling,
    [string]$EvidencePath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'casein-windows-acceptance.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-CheckedCommand {
    param([string]$Path, [string[]]$Arguments = @())

    & $Path @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$([IO.Path]::GetFileName($Path)) exited with code $LASTEXITCODE."
    }
}

function Assert-Path {
    param([string]$Path, [string]$Message)

    if (-not (Test-Path -LiteralPath $Path)) { throw $Message }
}

if (-not $AcceptDestructiveCleanMachineTest) {
    throw 'Pass -AcceptDestructiveCleanMachineTest only on a disposable clean Windows test account. The test removes Casein and its user data.'
}

$packageRoot = [IO.Path]::GetFullPath($PackageRoot)
$os = Get-CimInstance Win32_OperatingSystem
if ([Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'Clean-machine acceptance requires Windows 11 (build 22000 or newer).'
}
if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Clean-machine acceptance must run under Windows PowerShell 5.1.'
}

$unexpectedTools = @()
if ($RequireNoDeveloperTooling) {
    foreach ($name in @('mix.exe', 'elixir.exe', 'erl.exe', 'node.exe', 'npm.cmd', 'git.exe')) {
        if (Get-Command $name -ErrorAction SilentlyContinue) { $unexpectedTools += $name }
    }
    if ($unexpectedTools.Count -gt 0) {
        throw "Developer tooling is present on PATH: $($unexpectedTools -join ', ')"
    }
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        $distributions = @(& $wsl.Source --list --quiet 2>$null) |
            ForEach-Object { ([string]$_).Trim([char]0).Trim() } |
            Where-Object { $_ }
        if ($LASTEXITCODE -eq 0 -and $distributions.Count -gt 0) {
            throw "WSL distributions are installed: $($distributions -join ', ')"
        }
    }
}

$manifestPath = Join-Path $packageRoot 'windows\Casein.Release.psd1'
$installCommand = Join-Path $packageRoot 'Install-Casein.cmd'
$repairCommand = Join-Path $packageRoot 'Repair-Casein.cmd'
$uninstallCommand = Join-Path $packageRoot 'Uninstall-Casein.cmd'
Assert-Path $manifestPath 'The signed release manifest is missing.'
Assert-Path $installCommand 'The offline install command is missing.'
Assert-Path $repairCommand 'The offline repair command is missing.'
Assert-Path $uninstallCommand 'The offline uninstall command is missing.'

$signature = Get-AuthenticodeSignature -FilePath $manifestPath
if ($signature.Status -ne 'Valid') {
    throw "Production-signed acceptance requires a valid release manifest signature; status: $($signature.Status)."
}

$evidence = [ordered]@{
    schema = 1
    started_at_utc = [DateTime]::UtcNow.ToString('o')
    machine = $env:COMPUTERNAME
    os_caption = [string]$os.Caption
    os_version = [string]$os.Version
    powershell = [string]$PSVersionTable.PSVersion
    package_root = $packageRoot
    manifest_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
    signer_subject = [string]$signature.SignerCertificate.Subject
    signer_thumbprint = [string]$signature.SignerCertificate.Thumbprint
    no_developer_tooling_required = [bool]$RequireNoDeveloperTooling
    unexpected_tools = $unexpectedTools
    phases = @()
    result = 'running'
}

try {
    Invoke-CheckedCommand $installCommand
    $installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Casein'
    $currentPath = Join-Path $installRoot 'current.json'
    Assert-Path $currentPath 'Install did not create current.json.'
    $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
    $repairProbe = Join-Path ([string]$current.release_root) 'windows\New-CaseinSupportBundle.ps1'
    Assert-Path $repairProbe 'Installed release is incomplete.'
    $evidence.phases += 'install'

    Remove-Item -LiteralPath $repairProbe -Force
    Invoke-CheckedCommand $repairCommand
    Assert-Path $repairProbe 'Offline repair did not restore a damaged release file.'
    $evidence.phases += 'repair'

    Invoke-CheckedCommand $uninstallCommand
    if (Test-Path -LiteralPath $installRoot) { throw 'Uninstall left the Casein installation root behind.' }
    if (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Casein') {
        throw 'Uninstall left Apps & Features registration behind.'
    }
    $dataRoot = Join-Path $env:LOCALAPPDATA 'Casein'
    if (Test-Path -LiteralPath $dataRoot) {
        & (Join-Path $packageRoot 'windows\Uninstall-Casein.ps1') -RemoveUserData
    }
    if (Test-Path -LiteralPath $dataRoot) { throw 'Acceptance cleanup left Casein user data behind.' }
    $evidence.phases += 'uninstall'
    $evidence.result = 'passed'
} catch {
    $evidence.result = 'failed'
    $evidence.error = $_.Exception.Message
    throw
} finally {
    $evidence.completed_at_utc = [DateTime]::UtcNow.ToString('o')
    $evidenceDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($EvidencePath))
    New-Item -ItemType Directory -Force -Path $evidenceDirectory | Out-Null
    $evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
    Write-Host "Acceptance evidence: $EvidencePath"
}
