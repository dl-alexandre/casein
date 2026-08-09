[CmdletBinding()]
param(
    [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory = $true)]
    [switch]$AcceptDestructiveCleanMachineTest,
    [switch]$RequireNoDeveloperTooling,
    [switch]$RequirePackageRootWithSpace,
    [switch]$RequireLongPackageRoot,
    [switch]$RequireUncPackageRoot,
    [ValidateRange(120, 32000)][int]$MinimumLongPathLength = 180,
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

function New-CaseinPhaseRecord {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][datetime]$StartedAtUtc,
        [Parameter(Mandatory)][ValidateSet('passed', 'failed')][string]$Outcome,
        [string]$Detail = $null
    )

    $record = [ordered]@{
        name = $Name
        started_at_utc = $StartedAtUtc.ToUniversalTime().ToString('o')
        completed_at_utc = [DateTime]::UtcNow.ToString('o')
        outcome = $Outcome
    }
    if ($Detail) { $record.detail = $Detail }
    return $record
}

function Add-CaseinPhase {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][datetime]$StartedAtUtc,
        [Parameter(Mandatory)][ValidateSet('passed', 'failed')][string]$Outcome,
        [string]$Detail = $null
    )

    $Evidence.phases += ,(New-CaseinPhaseRecord -Name $Name -StartedAtUtc $StartedAtUtc -Outcome $Outcome -Detail $Detail)
}

if (-not $AcceptDestructiveCleanMachineTest) {
    throw 'Pass -AcceptDestructiveCleanMachineTest only on a disposable clean Windows test account. The test removes Casein and its user data.'
}

$packageRoot = [IO.Path]::GetFullPath($PackageRoot)
$packageRootIsUnc = $packageRoot.StartsWith('\\')
$packageRootHasSpace = $packageRoot.Contains(' ')
$packageRootLength = $packageRoot.Length
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
$filesManifestPath = Join-Path $packageRoot 'windows\Casein.Release.Files.json'
$installCommand = Join-Path $packageRoot 'Install-Casein.cmd'
$repairCommand = Join-Path $packageRoot 'Repair-Casein.cmd'
$uninstallCommand = Join-Path $packageRoot 'Uninstall-Casein.cmd'
$rebootHarness = Join-Path $packageRoot 'windows\Test-CaseinRebootPersistence.ps1'
Assert-Path $manifestPath 'The signed release manifest is missing.'
Assert-Path $filesManifestPath 'The signed release file manifest is missing.'
Assert-Path $installCommand 'The offline install command is missing.'
Assert-Path $repairCommand 'The offline repair command is missing.'
Assert-Path $uninstallCommand 'The offline uninstall command is missing.'
Assert-Path $rebootHarness 'The reboot-persistence acceptance harness is missing.'

$signature = Get-AuthenticodeSignature -FilePath $manifestPath
if ($signature.Status -ne 'Valid') {
    throw "Production-signed acceptance requires a valid release manifest signature; status: $($signature.Status)."
}

$evidence = [ordered]@{
    schema = 3
    started_at_utc = [DateTime]::UtcNow.ToString('o')
    machine = $env:COMPUTERNAME
    os_caption = [string]$os.Caption
    os_version = [string]$os.Version
    powershell = [string]$PSVersionTable.PSVersion
    package_root_kind = if ($packageRootIsUnc) { 'unc' } else { 'local' }
    package_root_length = $packageRootLength
    package_root_has_space = $packageRootHasSpace
    path_requirements = [ordered]@{
        space = [bool]$RequirePackageRootWithSpace
        long = [bool]$RequireLongPackageRoot
        unc = [bool]$RequireUncPackageRoot
        minimum_long_path_length = $MinimumLongPathLength
    }
    path_prerequisites = [ordered]@{
        package_root_kind = if ($packageRootIsUnc) { 'unc' } else { 'local' }
        package_root_length = $packageRootLength
        package_root_has_space = $packageRootHasSpace
        space_required = [bool]$RequirePackageRootWithSpace
        long_required = [bool]$RequireLongPackageRoot
        unc_required = [bool]$RequireUncPackageRoot
        minimum_long_path_length = $MinimumLongPathLength
    }
    manifest_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
    signer_subject = [string]$signature.SignerCertificate.Subject
    signer_thumbprint = [string]$signature.SignerCertificate.Thumbprint
    no_developer_tooling_required = [bool]$RequireNoDeveloperTooling
    unexpected_tools = $unexpectedTools
    phases = @()
    result = 'running'
}

try {
    $phaseStarted = [DateTime]::UtcNow
    if ($RequirePackageRootWithSpace -and -not $packageRootHasSpace) {
        throw 'The package root must contain a space for this acceptance run.'
    }
    if ($RequireLongPackageRoot -and $packageRootLength -lt $MinimumLongPathLength) {
        throw "The package root must meet the requested minimum length for this acceptance run."
    }
    if ($RequireUncPackageRoot -and -not $packageRootIsUnc) {
        throw 'The package root must be a UNC path for this acceptance run.'
    }
    Add-CaseinPhase -Evidence $evidence -Name 'package_path_contract' -StartedAtUtc $phaseStarted -Outcome 'passed'

    $phaseStarted = [DateTime]::UtcNow
    Invoke-CheckedCommand $installCommand
    $installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Casein'
    $currentPath = Join-Path $installRoot 'current.json'
    Assert-Path $currentPath 'Install did not create current.json.'
    $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
    $repairProbe = Join-Path ([string]$current.release_root) 'windows\New-CaseinSupportBundle.ps1'
    Assert-Path $repairProbe 'Installed release is incomplete.'
    Add-CaseinPhase -Evidence $evidence -Name 'install' -StartedAtUtc $phaseStarted -Outcome 'passed'

    $phaseStarted = [DateTime]::UtcNow
    $trayLibrary = Join-Path ([string]$current.release_root) 'windows\Casein.Tray.ps1'
    . $trayLibrary -ReleaseRoot ([string]$current.release_root) -LibraryOnly
    Set-CaseinStartup $true
    $startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Casein.lnk'
    Assert-Path $startupLink 'Launch at sign-in did not create its shortcut.'
    $startupShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($startupLink)
    $stableLauncher = Join-Path $installRoot 'Casein.Launcher.ps1'
    if (-not $startupShortcut.Arguments.Contains($stableLauncher)) {
        throw 'Launch at sign-in does not target the stable installed launcher.'
    }
    if ($startupShortcut.Arguments.Contains([string]$current.release_root)) {
        throw 'Launch at sign-in is pinned to a release-specific path.'
    }
    Add-CaseinPhase -Evidence $evidence -Name 'launch_at_sign_in' -StartedAtUtc $phaseStarted -Outcome 'passed'

    $phaseStarted = [DateTime]::UtcNow
    Remove-Item -LiteralPath $repairProbe -Force
    Invoke-CheckedCommand $repairCommand
    Assert-Path $repairProbe 'Offline repair did not restore a damaged release file.'
    Add-CaseinPhase -Evidence $evidence -Name 'repair' -StartedAtUtc $phaseStarted -Outcome 'passed'

    $phaseStarted = [DateTime]::UtcNow
    Invoke-CheckedCommand $uninstallCommand
    if (Test-Path -LiteralPath $installRoot) { throw 'Uninstall left the Casein installation root behind.' }
    if (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Casein') {
        throw 'Uninstall left Apps & Features registration behind.'
    }
    if (Test-Path -LiteralPath $startupLink) { throw 'Uninstall left the launch-at-sign-in shortcut behind.' }
    $dataRoot = Join-Path $env:LOCALAPPDATA 'Casein'
    if (Test-Path -LiteralPath $dataRoot) {
        & (Join-Path $packageRoot 'windows\Uninstall-Casein.ps1') -RemoveUserData
    }
    if (Test-Path -LiteralPath $dataRoot) { throw 'Acceptance cleanup left Casein user data behind.' }
    Add-CaseinPhase -Evidence $evidence -Name 'uninstall' -StartedAtUtc $phaseStarted -Outcome 'passed'
    $evidence.result = 'passed'
} catch {
    $evidence.result = 'failed'
    $evidence.error = $_.Exception.Message
    throw
} finally {
    $evidence.completed_at_utc = [DateTime]::UtcNow.ToString('o')
    $evidenceDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($EvidencePath))
    New-Item -ItemType Directory -Force -Path $evidenceDirectory | Out-Null
    $evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
    Write-Host "Acceptance evidence: $EvidencePath"
}
