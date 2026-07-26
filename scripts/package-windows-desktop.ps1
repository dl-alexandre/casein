[CmdletBinding()]
param(
    [string]$ReleasePath,
    [string]$OutputPath,
    [switch]$SkipBuild,
    [switch]$AllowDirty,
    [switch]$SkipPreviewRuntime,
    [string]$SigningCertificateThumbprint,
    [switch]$RequireSigned
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $ReleasePath) { $ReleasePath = Join-Path $root '_build\prod\rel\casein' }
if (-not $OutputPath) { $OutputPath = Join-Path $root 'dist\Casein-windows-x64' }
$releasePath = [IO.Path]::GetFullPath($ReleasePath)
$outputPath = [IO.Path]::GetFullPath($OutputPath)

function Get-SourceRevision {
    $git = Get-Command git.exe -ErrorAction Stop
    $revision = (& $git.Source -C $root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve the source revision for the Windows package'
    }

    if (-not $AllowDirty) {
        $changes = & $git.Source -C $root status --porcelain
        if ($LASTEXITCODE -ne 0) { throw 'Could not determine whether the source tree is clean' }
        if ($changes) {
            throw 'Refusing to package a dirty source tree. Commit the release changes or pass -AllowDirty for an explicitly non-shareable local build.'
        }
    }

    $revision
}

function Read-DesktopReleaseMetadata {
    param([string]$Path, [string]$Revision)

    $metadataPath = Join-Path $Path 'releases\casein.relmeta.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) {
        throw "Release metadata is missing at $metadataPath"
    }

    $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
    $mismatches = @()
    if ($metadata.revision -ne $Revision) { $mismatches += "revision=$($metadata.revision) (expected $Revision)" }
    if ($metadata.profile -ne 'desktop') { $mismatches += "profile=$($metadata.profile)" }
    if ($metadata.repo_adapter -ne 'sqlite') { $mismatches += "repo_adapter=$($metadata.repo_adapter)" }
    if ($metadata.target -ne 'windows-x86_64') { $mismatches += "target=$($metadata.target)" }
    if ($mismatches.Count -gt 0) {
        throw "Release metadata does not describe this Windows desktop build: $($mismatches -join '; ')"
    }

    $metadata
}

function New-DesktopArchive {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    # Compress-Archive can hang indefinitely while walking a Phoenix release on
    # current Windows builds. tar.exe ships with supported Windows versions and
    # uses libarchive's ZIP writer instead. Run it from inside the package so
    # the archive contains the payload, not its parent directory.
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        Push-Location $SourcePath
        try {
            & $tar.Source -a -c -f $DestinationPath .
            if ($LASTEXITCODE -ne 0) {
                throw "tar.exe failed while creating $DestinationPath"
            }
        } finally {
            Pop-Location
        }
    } else {
        Compress-Archive -Path (Join-Path $SourcePath '*') -DestinationPath $DestinationPath -CompressionLevel Optimal
    }

    if (-not (Test-Path -LiteralPath $DestinationPath) -or (Get-Item -LiteralPath $DestinationPath).Length -le 0) {
        throw "Archive creation produced no artifact at $DestinationPath"
    }
}

$sourceRevision = Get-SourceRevision

function Assert-WindowsPreviewRuntime {
    $scripts = Join-Path $root 'priv\scripts'
    $required = @(
        (Join-Path $scripts 'runtime\node.exe'),
        (Join-Path $scripts 'node_modules\playwright\package.json'),
        (Join-Path $scripts 'playwright-browsers')
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -gt 0) {
        throw "Windows preview runtime is incomplete. Run scripts\prepare-windows-preview-runtime.ps1 before packaging. Missing: $($missing -join ', ')"
    }
}

function Copy-DesktopTree {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $robocopy = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if ($robocopy) {
        & $robocopy.Source $SourcePath $DestinationPath /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
        # Robocopy uses 0-7 for successful copy states; 8+ means failure.
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy failed with exit code $LASTEXITCODE while copying the release"
        }
    } else {
        Copy-Item -Recurse -Force -Path (Join-Path $SourcePath '*') -Destination $DestinationPath
    }
}

function Remove-DesktopTree {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    if ($full -eq $root -or $full -eq [IO.Path]::GetPathRoot($full)) {
        throw "Refusing unsafe tree removal: $full"
    }
    if (Test-Path -LiteralPath $full) {
        $longPath = if ($full.StartsWith('\\')) { "\\?\UNC\$($full.Substring(2))" } else { "\\?\$full" }
        [IO.Directory]::Delete($longPath, $true)
    }
}

function Write-ReleaseTrustManifest {
    param([string]$PackagePath, [string]$Revision, [string]$Version)

    $certificate = $null
    $signedRelativeFiles = @()
    if ($SigningCertificateThumbprint) {
        $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$SigningCertificateThumbprint" -ErrorAction Stop
        $signable = Get-ChildItem -LiteralPath $PackagePath -Recurse -File |
            Where-Object { $_.Extension.ToLowerInvariant() -in @('.exe', '.dll', '.ps1', '.psm1') }
        foreach ($file in $signable) {
            $signature = Set-AuthenticodeSignature -FilePath $file.FullName -Certificate $certificate -HashAlgorithm SHA256
            if ($signature.Status -ne 'Valid') {
                throw "Executable signing failed for $($file.FullName): $($signature.StatusMessage)"
            }
        }
        $packagePrefixLength = $PackagePath.TrimEnd('\').Length + 1
        $signedRelativeFiles = @($signable | ForEach-Object { $_.FullName.Substring($packagePrefixLength) } | Sort-Object)
    } elseif ($RequireSigned) {
        throw 'A signing certificate thumbprint is required when -RequireSigned is set.'
    }

    $packagePrefixLength = $PackagePath.TrimEnd('\').Length + 1
    $relativeFiles = Get-ChildItem -LiteralPath $PackagePath -Recurse -File |
        Where-Object { $_.FullName -ne (Join-Path $PackagePath 'windows\Casein.Release.psd1') } |
        ForEach-Object { $_.FullName.Substring($packagePrefixLength) } |
        Sort-Object
    $entries = foreach ($relative in $relativeFiles) {
        $path = Join-Path $PackagePath $relative
        "        '$($relative.Replace("'", "''"))' = '$((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant())'"
    }
    $manifest = Join-Path $PackagePath 'windows\Casein.Release.psd1'
    $signedEntries = @($signedRelativeFiles | ForEach-Object { "        '$($_.Replace("'", "''"))'" })
    @"
@{
    Schema = 1
    Version = '$Version'
    Revision = '$Revision'
    SignedFiles = @(
$($signedEntries -join "`r`n")
    )
    Files = @{
$($entries -join "`r`n")
    }
}
"@ | Set-Content -LiteralPath $manifest -Encoding UTF8

    if ($certificate) {
        $signature = Set-AuthenticodeSignature -FilePath $manifest -Certificate $certificate -HashAlgorithm SHA256
        if ($signature.Status -ne 'Valid') { throw "Release manifest signing failed: $($signature.StatusMessage)" }
    }
}

function Write-SignedUpdateCatalog {
    param([string]$ManifestPath)

    if (-not $SigningCertificateThumbprint) {
        if ($RequireSigned) { throw 'Signed update metadata requires a signing certificate.' }
        return
    }
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$SigningCertificateThumbprint" -ErrorAction Stop
    $catalogPath = "$ManifestPath.cat"
    New-FileCatalog -Path $ManifestPath -CatalogFilePath $catalogPath -CatalogVersion 2.0 | Out-Null
    $signature = Set-AuthenticodeSignature -FilePath $catalogPath -Certificate $certificate -HashAlgorithm SHA256
    if ($signature.Status -ne 'Valid') { throw "Update catalog signing failed: $($signature.StatusMessage)" }
    if ((Test-FileCatalog -Path $ManifestPath -CatalogFilePath $catalogPath -Detailed).Status -ne 'Valid') {
        throw 'Signed update catalog does not match the emitted update manifest.'
    }
}

if (-not $SkipPreviewRuntime) {
    Assert-WindowsPreviewRuntime
}

if ($outputPath -eq $root -or $outputPath -eq [IO.Path]::GetPathRoot($outputPath)) {
    throw "Refusing unsafe output path: $outputPath"
}

if (-not $SkipBuild) {
    $mise = Get-Command mise -ErrorAction SilentlyContinue
    $mix = Get-Command mix.bat -ErrorAction SilentlyContinue
    if (-not $mise -and -not $mix) {
        throw 'Neither mise nor mix.bat is available on PATH'
    }

    $runMix = {
        param([string[]]$MixArguments)
        if ($mise) {
            & $mise.Source exec -- mix @MixArguments
        } else {
            & $mix.Source @MixArguments
        }
        if ($LASTEXITCODE -ne 0) {
            throw "mix $($MixArguments -join ' ') failed"
        }
    }

    Push-Location $root
    try {
        $env:MIX_ENV = 'prod'
        $env:CASEIN_NATIVE_WINDOWS = 'true'
        $env:CASEIN_REPO_ADAPTER = 'sqlite'
        $env:CASEIN_RELEASE_PROFILE = 'desktop'
        $env:CASEIN_GIT_REVISION = $sourceRevision
        if (-not (Test-Path -LiteralPath (Join-Path $root 'assets\node_modules\@codemirror\view'))) {
            throw 'Asset dependencies are missing; run mix assets.npm before packaging'
        }
        # The colocated-assets compiler writes into assets/node_modules on Windows.
        # Force it after dependency installation so a prior compile cannot leave the
        # esbuild import missing merely because node_modules did not exist yet.
        & $runMix @('compile', '--force')
        & $runMix @('assets.deploy')
        & $runMix @('release', 'casein', '--overwrite')
    } finally {
        Pop-Location
    }
}

$releaseBat = Join-Path $releasePath 'bin\casein.bat'
if (-not (Test-Path -LiteralPath $releaseBat)) {
    throw "Windows release not found at $releaseBat"
}
$metadata = Read-DesktopReleaseMetadata -Path $releasePath -Revision $sourceRevision

if (Test-Path -LiteralPath $outputPath) {
    Remove-DesktopTree -Path $outputPath
}
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
Copy-DesktopTree -SourcePath $releasePath -DestinationPath $outputPath

if (-not $SkipPreviewRuntime) {
    $releaseScripts = Get-ChildItem -LiteralPath (Join-Path $outputPath 'lib') -Directory |
        ForEach-Object { Join-Path $_.FullName 'priv\scripts' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'preview_playwright.mjs') } |
        Select-Object -First 1
    if (-not $releaseScripts) { throw 'Built release omitted the Playwright helper script' }

    # Mix copies application priv before packaging, where deeply nested Chromium
    # resources can exceed legacy Win32 path handling. Overlay the prepared tree
    # with robocopy, which preserves the complete long-path browser payload.
    foreach ($name in @('runtime', 'node_modules', 'playwright-browsers')) {
        Copy-DesktopTree -SourcePath (Join-Path $root "priv\scripts\$name") -DestinationPath (Join-Path $releaseScripts $name)
    }

    $headless = Get-ChildItem -LiteralPath (Join-Path $releaseScripts 'playwright-browsers') -Directory |
        Where-Object Name -Like 'chromium_headless_shell-*' |
        Select-Object -First 1
    if (-not (Test-Path -LiteralPath (Join-Path $releaseScripts 'runtime\node.exe')) -or
        -not (Test-Path -LiteralPath (Join-Path $releaseScripts 'node_modules\playwright\package.json')) -or
        -not $headless -or
        -not (Test-Path -LiteralPath (Join-Path $headless.FullName 'INSTALLATION_COMPLETE'))) {
        throw 'Packaged release omitted part of the self-contained Windows preview runtime'
    }
}
New-Item -ItemType Directory -Force -Path (Join-Path $outputPath 'windows') | Out-Null
Copy-Item -Force -LiteralPath @(
    (Join-Path $root 'windows\Casein.Tray.ps1'),
    (Join-Path $root 'windows\Casein.TrustedLan.ps1'),
    (Join-Path $root 'windows\Casein.Launcher.ps1'),
    (Join-Path $root 'windows\Install-Casein.ps1'),
    (Join-Path $root 'windows\Uninstall-Casein.ps1'),
    (Join-Path $root 'windows\Repair-Casein.ps1'),
    (Join-Path $root 'windows\Rollback-Casein.ps1'),
    (Join-Path $root 'windows\New-CaseinSupportBundle.ps1'),
    (Join-Path $root 'windows\Start-Casein.cmd')
) -Destination (Join-Path $outputPath 'windows')
Copy-Item -Force -LiteralPath (Join-Path $root 'priv\static\images\pwa-icon-192.png') -Destination (Join-Path $outputPath 'windows\Casein.png')
Write-ReleaseTrustManifest -PackagePath $outputPath -Revision $sourceRevision -Version $metadata.version

$docsPath = Join-Path $outputPath 'docs'
if (Test-Path -LiteralPath $docsPath) {
    throw "Refusing to package internal documentation at $docsPath"
}

$shortRevision = $sourceRevision.Substring(0, 7)
$archiveBase = "Casein-windows-x64-$($metadata.version)-$shortRevision"
$archivePath = Join-Path (Split-Path -Parent $outputPath) "$archiveBase.zip"
$manifestPath = Join-Path (Split-Path -Parent $outputPath) "$archiveBase.manifest.json"
$shaPath = Join-Path (Split-Path -Parent $outputPath) "$archiveBase.zip.sha256"
Remove-Item -LiteralPath $archivePath, $manifestPath, $shaPath -Force -ErrorAction SilentlyContinue
New-DesktopArchive -SourcePath $outputPath -DestinationPath $archivePath
$archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()

[ordered]@{
    metadata_version = 1
    app = 'casein'
    version = $metadata.version
    revision = $sourceRevision
    profile = $metadata.profile
    repo_adapter = $metadata.repo_adapter
    target = $metadata.target
    artifact = [IO.Path]::GetFileName($archivePath)
    sha256 = $archiveHash
    bytes = (Get-Item -LiteralPath $archivePath).Length
    built_at_utc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-SignedUpdateCatalog -ManifestPath $manifestPath
Set-Content -LiteralPath $shaPath -Value "$archiveHash *$([IO.Path]::GetFileName($archivePath))" -Encoding ascii

Write-Host "Packaged Casein Windows desktop runtime: $outputPath"
Write-Host "Launch: $outputPath\windows\Start-Casein.cmd"
Write-Host "Artifact: $archivePath"
Write-Host "SHA-256: $shaPath"
