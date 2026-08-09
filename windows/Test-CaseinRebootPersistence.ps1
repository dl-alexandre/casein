[CmdletBinding()]
param(
    [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory = $true)]
    [switch]$AcceptDestructiveCleanMachineTest,
    [ValidateSet('prepare', 'continue', 'auto')]
    [string]$Stage = 'auto',
    [string]$EvidencePath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'casein-windows-reboot-acceptance.json'),
    [string]$ContinuationPath = (Join-Path $env:LOCALAPPDATA 'Casein\acceptance\reboot-continuation.json'),
    [switch]$SkipUninstall
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

function Get-CaseinBootStamp {
    $os = Get-CimInstance Win32_OperatingSystem
    return [ordered]@{
        last_boot_up_time_utc = ([DateTime]$os.LastBootUpTime).ToUniversalTime().ToString('o')
        os_version = [string]$os.Version
        os_caption = [string]$os.Caption
    }
}

function New-CaseinPhaseRecord {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][datetime]$StartedAtUtc,
        [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'awaiting_reboot')][string]$Outcome,
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

function Write-CaseinEvidence {
    param([hashtable]$Evidence, [string]$Path)

    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $Evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-CaseinContinuation {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -Raw -LiteralPath $Path
    try {
        return $raw | ConvertFrom-Json
    } catch {
        throw 'Continuation marker is malformed and cannot be resumed safely.'
    }
}

function Write-CaseinContinuation {
    param([hashtable]$Marker, [string]$Path)

    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $Marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Clear-CaseinContinuation {
    param([string]$Path)

    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $directory = Split-Path -Parent $Path
    if ((Test-Path -LiteralPath $directory) -and -not (Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
    }
}

function Assert-StableStartupShortcut {
    param([string]$ReleaseRoot)

    $startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Casein.lnk'
    Assert-Path $startupLink 'Launch at sign-in shortcut is missing after reboot prepare/continue.'
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($startupLink)
    $stableLauncher = Join-Path $env:LOCALAPPDATA 'Programs\Casein\Casein.Launcher.ps1'
    if (-not $shortcut.Arguments.Contains($stableLauncher)) {
        throw 'Launch at sign-in does not target the stable installed launcher.'
    }
    if ($ReleaseRoot -and $shortcut.Arguments.Contains($ReleaseRoot)) {
        throw 'Launch at sign-in is pinned to a release-specific path.'
    }
    return $stableLauncher
}

if (-not $AcceptDestructiveCleanMachineTest) {
    throw 'Pass -AcceptDestructiveCleanMachineTest only on a disposable clean Windows test account. The test installs Casein and may remove its user data.'
}

$packageRoot = [IO.Path]::GetFullPath($PackageRoot)
$packageRootIsUnc = $packageRoot.StartsWith('\\')
$packageRootHasSpace = $packageRoot.Contains(' ')
$packageRootLength = $packageRoot.Length
$os = Get-CimInstance Win32_OperatingSystem
if ([Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'Reboot-persistence acceptance requires Windows 11 (build 22000 or newer).'
}
if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Reboot-persistence acceptance must run under Windows PowerShell 5.1.'
}

$installCommand = Join-Path $packageRoot 'Install-Casein.cmd'
$uninstallCommand = Join-Path $packageRoot 'Uninstall-Casein.cmd'
$manifestPath = Join-Path $packageRoot 'windows\Casein.Release.psd1'
Assert-Path $manifestPath 'The signed release manifest is missing.'
Assert-Path $installCommand 'The offline install command is missing.'
Assert-Path $uninstallCommand 'The offline uninstall command is missing.'

$signature = Get-AuthenticodeSignature -FilePath $manifestPath
if ($signature.Status -ne 'Valid') {
    throw "Production-signed acceptance requires a valid release manifest signature; status: $($signature.Status)."
}

$existingContinuation = Read-CaseinContinuation -Path $ContinuationPath
$resolvedStage = $Stage
if ($Stage -eq 'auto') {
    if ($existingContinuation -and [string]$existingContinuation.stage -eq 'awaiting_reboot') {
        $resolvedStage = 'continue'
    } else {
        $resolvedStage = 'prepare'
    }
}

$boot = Get-CaseinBootStamp
$evidence = [ordered]@{
    schema = 1
    kind = 'windows_reboot_persistence'
    started_at_utc = [DateTime]::UtcNow.ToString('o')
    machine = $env:COMPUTERNAME
    os_caption = [string]$os.Caption
    os_version = [string]$os.Version
    powershell = [string]$PSVersionTable.PSVersion
    package_root_kind = if ($packageRootIsUnc) { 'unc' } else { 'local' }
    package_root_length = $packageRootLength
    package_root_has_space = $packageRootHasSpace
    path_prerequisites = [ordered]@{
        package_root_kind = if ($packageRootIsUnc) { 'unc' } else { 'local' }
        package_root_length = $packageRootLength
        package_root_has_space = $packageRootHasSpace
    }
    manifest_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
    signer_subject = [string]$signature.SignerCertificate.Subject
    signer_thumbprint = [string]$signature.SignerCertificate.Thumbprint
    stage = $resolvedStage
    boot = $boot
    phases = @()
    result = 'running'
}

try {
    if ($resolvedStage -eq 'prepare') {
        if ($existingContinuation) {
            throw 'A reboot continuation marker already exists. Pass -Stage continue, or clear the marker after finishing or abandoning the prior run.'
        }

        $phaseStarted = [DateTime]::UtcNow
        Invoke-CheckedCommand $installCommand
        $installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Casein'
        $currentPath = Join-Path $installRoot 'current.json'
        Assert-Path $currentPath 'Install did not create current.json.'
        $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
        $releaseRoot = [string]$current.release_root
        $evidence.phases += ,(New-CaseinPhaseRecord -Name 'install' -StartedAtUtc $phaseStarted -Outcome 'passed')

        $phaseStarted = [DateTime]::UtcNow
        $trayLibrary = Join-Path $releaseRoot 'windows\Casein.Tray.ps1'
        . $trayLibrary -ReleaseRoot $releaseRoot -LibraryOnly
        Set-CaseinStartup $true
        $stableLauncher = Assert-StableStartupShortcut -ReleaseRoot $releaseRoot
        $evidence.phases += ,(New-CaseinPhaseRecord -Name 'launch_at_sign_in' -StartedAtUtc $phaseStarted -Outcome 'passed')

        $originPath = Join-Path $env:LOCALAPPDATA 'Casein\origin.json'
        $originIdPrefix = $null
        if (Test-Path -LiteralPath $originPath) {
            try {
                $origin = Get-Content -Raw -LiteralPath $originPath | ConvertFrom-Json
                $originId = [string]$origin.origin_id
                if ($originId.StartsWith('windows-')) {
                    $originIdPrefix = 'windows-'
                }
            } catch {
                $originIdPrefix = $null
            }
        }

        $marker = [ordered]@{
            schema = 1
            kind = 'casein_reboot_continuation'
            stage = 'awaiting_reboot'
            created_at_utc = [DateTime]::UtcNow.ToString('o')
            prepare_boot_last_boot_up_time_utc = [string]$boot.last_boot_up_time_utc
            release_version = [string]$current.version
            release_revision = [string]$current.revision
            has_stable_launcher = [bool](Test-Path -LiteralPath $stableLauncher)
            origin_id_prefix = $originIdPrefix
            evidence_path_kind = if ([IO.Path]::IsPathRooted($EvidencePath)) { 'absolute' } else { 'relative' }
        }
        Write-CaseinContinuation -Marker $marker -Path $ContinuationPath

        $phaseStarted = [DateTime]::UtcNow
        $evidence.phases += ,(New-CaseinPhaseRecord -Name 'continuation_marker' -StartedAtUtc $phaseStarted -Outcome 'awaiting_reboot' -Detail 'Reboot the host, then re-run this script with -Stage continue (or -Stage auto).')
        $evidence.result = 'awaiting_reboot'
        $evidence.next_step = 'reboot_and_continue'
        Write-Host 'Prepared reboot-persistence acceptance. Reboot this disposable host, then re-run with -Stage continue (or -Stage auto).'
        return
    }

    if (-not $existingContinuation) {
        throw 'No reboot continuation marker was found. Run -Stage prepare first, reboot, then -Stage continue.'
    }
    if ([string]$existingContinuation.stage -ne 'awaiting_reboot') {
        throw "Continuation marker stage is '$($existingContinuation.stage)'; expected awaiting_reboot."
    }
    if ([int]$existingContinuation.schema -ne 1) {
        throw "Unsupported continuation marker schema: $($existingContinuation.schema)."
    }

    $phaseStarted = [DateTime]::UtcNow
    $prepareBoot = [string]$existingContinuation.prepare_boot_last_boot_up_time_utc
    if (-not $prepareBoot) {
        throw 'Continuation marker is missing the prepare-stage boot stamp.'
    }
    if ($prepareBoot -eq [string]$boot.last_boot_up_time_utc) {
        throw 'Host boot stamp is unchanged. Reboot before continuing reboot-persistence acceptance.'
    }
    $evidence.phases += ,(New-CaseinPhaseRecord -Name 'boot_changed' -StartedAtUtc $phaseStarted -Outcome 'passed')
    $evidence.prepare_boot_last_boot_up_time_utc = $prepareBoot
    $evidence.continue_boot_last_boot_up_time_utc = [string]$boot.last_boot_up_time_utc

    $phaseStarted = [DateTime]::UtcNow
    $installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Casein'
    $currentPath = Join-Path $installRoot 'current.json'
    Assert-Path $currentPath 'Installed release identity is missing after reboot.'
    $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
    if ([string]$existingContinuation.release_revision -and
        [string]$current.revision -ne [string]$existingContinuation.release_revision) {
        throw 'Installed release revision changed across reboot without an explicit update.'
    }
    $stableLauncher = Assert-StableStartupShortcut -ReleaseRoot ([string]$current.release_root)
    if (-not (Test-Path -LiteralPath $stableLauncher)) {
        throw 'Stable launcher is missing after reboot.'
    }
    $evidence.phases += ,(New-CaseinPhaseRecord -Name 'post_reboot_install_and_autostart' -StartedAtUtc $phaseStarted -Outcome 'passed')

    if (-not $SkipUninstall) {
        $phaseStarted = [DateTime]::UtcNow
        Invoke-CheckedCommand $uninstallCommand
        if (Test-Path -LiteralPath $installRoot) { throw 'Uninstall left the Casein installation root behind.' }
        $startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Casein.lnk'
        if (Test-Path -LiteralPath $startupLink) { throw 'Uninstall left the launch-at-sign-in shortcut behind.' }
        $dataRoot = Join-Path $env:LOCALAPPDATA 'Casein'
        if (Test-Path -LiteralPath $dataRoot) {
            & (Join-Path $packageRoot 'windows\Uninstall-Casein.ps1') -RemoveUserData
        }
        if (Test-Path -LiteralPath $dataRoot) { throw 'Acceptance cleanup left Casein user data behind.' }
        $evidence.phases += ,(New-CaseinPhaseRecord -Name 'uninstall' -StartedAtUtc $phaseStarted -Outcome 'passed')
    }

    Clear-CaseinContinuation -Path $ContinuationPath
    $evidence.result = 'passed'
} catch {
    $evidence.result = 'failed'
    $evidence.error = $_.Exception.Message
    throw
} finally {
    $evidence.completed_at_utc = [DateTime]::UtcNow.ToString('o')
    Write-CaseinEvidence -Evidence $evidence -Path $EvidencePath
    Write-Host "Acceptance evidence: $EvidencePath"
}
