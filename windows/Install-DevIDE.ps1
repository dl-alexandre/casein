[CmdletBinding()]
param(
    [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Launch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-ReleaseMetadata {
    param([string]$Root)

    $path = Join-Path $Root 'releases\dev_ide.relmeta.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Release metadata is missing at $path" }
    $metadata = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    if ($metadata.profile -ne 'desktop' -or $metadata.repo_adapter -ne 'sqlite' -or $metadata.target -ne 'windows-x86_64') {
        throw 'This package is not a Windows desktop SQLite release.'
    }
    $metadata
}

function Stop-InstalledRuntime {
    param([string]$DataRoot)

    $pidPath = Join-Path $DataRoot 'runtime.pid'
    if (-not (Test-Path -LiteralPath $pidPath)) { return }
    $runtimePid = 0
    [void][int]::TryParse((Get-Content -Raw -LiteralPath $pidPath).Trim(), [ref]$runtimePid)
    if ($runtimePid -gt 0 -and (Get-Process -Id $runtimePid -ErrorAction SilentlyContinue)) {
        & taskkill.exe /PID $runtimePid /T /F *> $null
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}

function Backup-UserData {
    param([string]$DataRoot, [string]$BackupRoot)

    if (-not (Test-Path -LiteralPath $DataRoot)) { return $null }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $backup = Join-Path $BackupRoot "before-update-$stamp"
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    # Credentials are machine/user-bound DPAPI blobs and are neither useful nor
    # appropriate in update backups. The live files remain in DataRoot.
    foreach ($name in @('devide.sqlite3', 'desktop-host.json')) {
        $source = Join-Path $DataRoot $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $backup -Force }
    }
    $backup
}

$packageRoot = [IO.Path]::GetFullPath($PackageRoot)
$metadata = Read-ReleaseMetadata $packageRoot
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\DevIDE'
$releasesRoot = Join-Path $installRoot 'releases'
$dataRoot = Join-Path $env:LOCALAPPDATA 'DevIDE'
$backupRoot = Join-Path $dataRoot 'backups'
$releaseId = "$($metadata.version)-$($metadata.revision.Substring(0, 7))"
$destination = Join-Path $releasesRoot $releaseId
$stage = "$destination.staging-$PID"
$currentPath = Join-Path $installRoot 'current.json'

New-Item -ItemType Directory -Force -Path $releasesRoot, $backupRoot | Out-Null
Stop-InstalledRuntime $dataRoot
$backup = Backup-UserData $dataRoot $backupRoot

try {
    if (-not (Test-Path -LiteralPath $destination)) {
        Copy-Item -Recurse -Force -LiteralPath $packageRoot -Destination $stage
        Move-Item -LiteralPath $stage -Destination $destination
    }

    $current = [ordered]@{
        schema = 1
        version = $metadata.version
        revision = $metadata.revision
        release_root = $destination
        previous_data_backup = $backup
        installed_at_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json
    $temporaryCurrent = "$currentPath.$PID.tmp"
    Set-Content -LiteralPath $temporaryCurrent -Value $current -Encoding UTF8
    Move-Item -LiteralPath $temporaryCurrent -Destination $currentPath -Force

    $launcher = Join-Path $installRoot 'DevIDE.Launcher.ps1'
    Copy-Item -LiteralPath (Join-Path $packageRoot 'windows\DevIDE.Launcher.ps1') -Destination $launcher -Force
    $installedUninstaller = Join-Path $installRoot 'Uninstall-DevIDE.ps1'
    Copy-Item -LiteralPath (Join-Path $packageRoot 'windows\Uninstall-DevIDE.ps1') -Destination $installedUninstaller -Force
    $installedRepair = Join-Path $installRoot 'Repair-DevIDE.ps1'
    Copy-Item -LiteralPath (Join-Path $packageRoot 'windows\Repair-DevIDE.ps1') -Destination $installedRepair -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot 'windows\New-DevIDESupportBundle.ps1') -Destination (Join-Path $installRoot 'New-DevIDESupportBundle.ps1') -Force
    Set-Content -LiteralPath (Join-Path $installRoot 'DevIDE.cmd') -Encoding ascii -Value "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0DevIDE.Launcher.ps1`""

    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DevIDE'
    New-Item -Path $uninstallKey -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'DevIDE' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value $metadata.version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name Publisher -Value 'DevIDE' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $installRoot -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name NoRepair -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name RepairPath -Value "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$installedRepair`" -Launch" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name UninstallString -Value "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$installedUninstaller`"" -PropertyType String -Force | Out-Null

    if ($Launch) { & $launcher }
    Write-Host "Installed DevIDE $releaseId for $env:USERNAME"
    Write-Host "Launcher: $(Join-Path $installRoot 'DevIDE.cmd')"
} catch {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    throw
}
