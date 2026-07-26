[CmdletBinding()]
param(
    [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Launch,
    [switch]$RequireSigned
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-ReleaseMetadata {
    param([string]$Root)

    $path = Join-Path $Root 'releases\casein.relmeta.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Release metadata is missing at $path" }
    $metadata = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    if ($metadata.profile -ne 'desktop' -or $metadata.repo_adapter -ne 'sqlite' -or $metadata.target -ne 'windows-x86_64') {
        throw 'This package is not a Windows desktop SQLite release.'
    }
    $metadata
}

function Test-ReleaseTrust {
    param([string]$Root)

    $manifestPath = Join-Path $Root 'windows\Casein.Release.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Release trust manifest is missing.' }
    $signature = Get-AuthenticodeSignature -FilePath $manifestPath
    $signatureRequired = $RequireSigned -or $env:CASEIN_REQUIRE_SIGNED_RELEASES -eq '1'
    if ($signatureRequired -and $signature.Status -ne 'Valid') {
        throw "A trusted Authenticode release signature is required; status: $($signature.Status)."
    }
    if ($signature.Status -notin @('Valid', 'NotSigned')) {
        throw "Release manifest signature is invalid: $($signature.Status)."
    }

    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    if ($manifest.Schema -ne 1 -or -not $manifest.Files) { throw 'Release trust manifest is invalid.' }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    foreach ($entry in $manifest.Files.GetEnumerator()) {
        $path = [IO.Path]::GetFullPath((Join-Path $Root ([string]$entry.Key)))
        if (-not $path.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Release trust manifest contains an unsafe path: $($entry.Key)"
        }
        if (-not (Test-Path -LiteralPath $path)) { throw "Release file is missing: $($entry.Key)" }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if ($actual -ne ([string]$entry.Value).ToLowerInvariant()) {
            throw "Release integrity check failed: $($entry.Key)"
        }
    }
    if ($signatureRequired) {
        if (-not $manifest.SignedFiles -or $manifest.SignedFiles.Count -eq 0) {
            throw 'Signed release manifest does not declare its signed executables.'
        }
        foreach ($relative in @($manifest.SignedFiles)) {
            $path = [IO.Path]::GetFullPath((Join-Path $Root ([string]$relative)))
            if (-not $path.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Signed executable list contains an unsafe path: $relative"
            }
            $fileSignature = Get-AuthenticodeSignature -FilePath $path
            if ($fileSignature.Status -ne 'Valid') {
                throw "Packaged executable is not trusted: $relative ($($fileSignature.Status))."
            }
        }
    }
    $manifest
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

function Copy-ReleaseTree {
    param([string]$Source, [string]$Destination)

    $robocopy = Get-Command robocopy.exe -ErrorAction Stop
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & $robocopy.Source $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { throw "Release copy failed with robocopy exit code $LASTEXITCODE" }
}

function Remove-ReleaseTree {
    param([string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $releases = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\Casein\releases')).TrimEnd('\') + '\'
    if (-not $full.StartsWith($releases, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing unsafe release cleanup: $full"
    }
    if (Test-Path -LiteralPath $full) {
        $longPath = if ($full.StartsWith('\\')) { "\\?\UNC\$($full.Substring(2))" } else { "\\?\$full" }
        [IO.Directory]::Delete($longPath, $true)
    }
}

function Backup-UserData {
    param([string]$DataRoot, [string]$BackupRoot)

    if (-not (Test-Path -LiteralPath $DataRoot)) { return $null }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $backup = Join-Path $BackupRoot "before-update-$stamp"
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    # Credentials are machine/user-bound DPAPI blobs and are neither useful nor
    # appropriate in update backups. The live files remain in DataRoot.
    foreach ($name in @('casein.sqlite3', 'desktop-host.json')) {
        $source = Join-Path $DataRoot $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $backup -Force }
    }
    $backup
}

$packageRoot = [IO.Path]::GetFullPath($PackageRoot)
$trust = Test-ReleaseTrust $packageRoot
$metadata = Read-ReleaseMetadata $packageRoot
if ($trust.Version -ne $metadata.version -or $trust.Revision -ne $metadata.revision) {
    throw 'Release trust identity does not match release metadata.'
}
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Casein'
$releasesRoot = Join-Path $installRoot 'releases'
$dataRoot = Join-Path $env:LOCALAPPDATA 'Casein'
$backupRoot = Join-Path $dataRoot 'backups'
$releaseId = "$($metadata.version)-$($metadata.revision.Substring(0, 7))"
$destination = Join-Path $releasesRoot $releaseId
$stage = "$destination.staging-$PID"
$currentPath = Join-Path $installRoot 'current.json'
$previousReleaseRoot = $null
if (Test-Path -LiteralPath $currentPath) {
    $existingCurrent = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
    $previousReleaseRoot = [string]$existingCurrent.release_root
}

New-Item -ItemType Directory -Force -Path $releasesRoot, $backupRoot | Out-Null
Stop-InstalledRuntime $dataRoot
$backup = Backup-UserData $dataRoot $backupRoot

try {
    if (-not (Test-Path -LiteralPath $destination)) {
        Copy-ReleaseTree -Source $packageRoot -Destination $stage
        Move-Item -LiteralPath $stage -Destination $destination
    }

    $current = [ordered]@{
        schema = 1
        version = $metadata.version
        revision = $metadata.revision
        release_root = $destination
        previous_release_root = $previousReleaseRoot
        previous_data_backup = $backup
        installed_at_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json
    $temporaryCurrent = "$currentPath.$PID.tmp"
    Set-Content -LiteralPath $temporaryCurrent -Value $current -Encoding UTF8
    Move-Item -LiteralPath $temporaryCurrent -Destination $currentPath -Force

    $launcher = Join-Path $installRoot 'Casein.Launcher.ps1'
    Copy-Item -LiteralPath (Join-Path $packageRoot 'windows\Casein.Launcher.ps1') -Destination $launcher -Force
    $installedUninstaller = Join-Path $installRoot 'Uninstall-Casein.ps1'
    Copy-Item -LiteralPath (Join-Path $packageRoot 'windows\Uninstall-Casein.ps1') -Destination $installedUninstaller -Force
    $installedRepair = Join-Path $installRoot 'Repair-Casein.ps1'
    Copy-Item -LiteralPath (Join-Path $packageRoot 'windows\Repair-Casein.ps1') -Destination $installedRepair -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot 'windows\Rollback-Casein.ps1') -Destination (Join-Path $installRoot 'Rollback-Casein.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot 'windows\New-CaseinSupportBundle.ps1') -Destination (Join-Path $installRoot 'New-CaseinSupportBundle.ps1') -Force
    Set-Content -LiteralPath (Join-Path $installRoot 'Casein.cmd') -Encoding ascii -Value "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Casein.Launcher.ps1`""

    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Casein'
    New-Item -Path $uninstallKey -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'Casein' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value $metadata.version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name Publisher -Value 'Casein' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $installRoot -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name NoRepair -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name RepairPath -Value "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$installedRepair`" -Launch" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name UninstallString -Value "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$installedUninstaller`"" -PropertyType String -Force | Out-Null

    if ($Launch) { & $launcher }
    Write-Host "Installed Casein $releaseId for $env:USERNAME"
    Write-Host "Launcher: $(Join-Path $installRoot 'Casein.cmd')"
} catch {
    if (Test-Path -LiteralPath $stage) { Remove-ReleaseTree -Path $stage }
    throw
}
