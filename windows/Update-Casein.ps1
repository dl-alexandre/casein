[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Casein'),
    [string]$ManifestUrl,
    [switch]$Install,
    [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-CaseinUpdatePlan {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][psobject]$Current
    )

    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    if ($manifest.manifest_version -ne 1 -or -not $manifest.channel -or -not $manifest.artifacts) {
        throw 'The update channel manifest is invalid or unsupported.'
    }
    if ([string]$manifest.channel -ne [string]$Current.channel) {
        throw "Refusing update channel change from $($Current.channel) to $($manifest.channel)."
    }
    $matches = @($manifest.artifacts | Where-Object {
        $_.app -eq $Current.app -and
        $_.profile -eq $Current.profile -and
        $_.target -eq $Current.target -and
        $_.repo_adapter -eq $Current.repo_adapter
    })
    if ($matches.Count -ne 1) { throw "Expected exactly one compatible Windows artifact; found $($matches.Count)." }
    $artifact = $matches[0]
    if (-not ([string]$artifact.url).StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The update artifact URL must use HTTPS.'
    }
    if ([string]$artifact.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [long]$artifact.size -le 0) {
        throw 'The update artifact size or SHA-256 is invalid.'
    }
    [pscustomobject]@{ Manifest = $manifest; Artifact = $artifact }
}

function Assert-CaseinUpdateCatalog {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][string]$ExpectedSignerThumbprint
    )

    if (-not (Test-Path -LiteralPath $CatalogPath)) { throw 'The signed update catalog is missing.' }
    $signature = Get-AuthenticodeSignature -FilePath $CatalogPath
    if ($signature.Status -ne 'Valid') { throw "The update catalog signer is not trusted: $($signature.Status)." }
    if (-not $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ne $ExpectedSignerThumbprint) {
        throw 'The update catalog signer does not match the installed release signer.'
    }
    $catalogResult = Test-FileCatalog -Path $ManifestPath -CatalogFilePath $CatalogPath -Detailed
    if ($catalogResult.Status -ne 'Valid') { throw 'The update manifest does not match its signed catalog.' }
}

function Receive-CaseinUpdateFile {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Destination)

    $uri = [Uri]$Url
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'Update URLs must be credential-free HTTPS URLs without query strings or fragments.'
    }
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $Destination -TimeoutSec 120
}

function Wait-CaseinUpdateHealth {
    param([int]$Port, [int]$TimeoutSeconds = 60)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "http://127.0.0.1:$Port/healthz"
            if ($response.StatusCode -eq 200) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    $false
}

function Stop-CaseinTrayForUpdate {
    $trayPidPath = Join-Path $env:LOCALAPPDATA 'Casein\tray.pid'
    if (-not (Test-Path -LiteralPath $trayPidPath)) { return }
    $trayPid = 0
    [void][int]::TryParse((Get-Content -Raw -LiteralPath $trayPidPath).Trim(), [ref]$trayPid)
    if ($trayPid -gt 0 -and $trayPid -ne $PID -and (Get-Process -Id $trayPid -ErrorAction SilentlyContinue)) {
        # Do not use /T: the updater was launched by the tray and must survive
        # the handoff. Closing the tray disposes its kill-on-close Job Object.
        & taskkill.exe /PID $trayPid /F *> $null
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ((Get-Process -Id $trayPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
    }
}

if ($LibraryOnly) { return }

$currentPath = Join-Path $InstallRoot 'current.json'
if (-not (Test-Path -LiteralPath $currentPath)) { throw 'Casein is not installed.' }
$currentInstall = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
$signerProperty = $currentInstall.PSObject.Properties['signer_thumbprint']
$signerThumbprint = if ($signerProperty) { [string]$signerProperty.Value } else { $null }
if (-not $signerThumbprint) {
    throw 'The installed release has no pinned production signer. Reinstall a signed Casein package before using the update channel.'
}
$releaseMetadataPath = Join-Path ([string]$currentInstall.release_root) 'releases\casein.relmeta.json'
$current = Get-Content -Raw -LiteralPath $releaseMetadataPath | ConvertFrom-Json
if (-not $ManifestUrl) { $ManifestUrl = [string]$current.update_manifest_url }
$manifestUri = [Uri]$ManifestUrl
if ($manifestUri.Scheme -ne 'https' -or $manifestUri.UserInfo -or $manifestUri.Query -or $manifestUri.Fragment) {
    throw 'The configured update channel must be a credential-free HTTPS URL without a query string or fragment.'
}

$stage = Join-Path $env:TEMP ("Casein-update-{0}" -f [Guid]::NewGuid().ToString('N'))
$updateLog = Join-Path $env:LOCALAPPDATA 'Casein\update.log'
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $manifestPath = Join-Path $stage 'channel.json'
    $catalogPath = Join-Path $stage 'channel.json.cat'
    Receive-CaseinUpdateFile -Url $ManifestUrl -Destination $manifestPath
    Receive-CaseinUpdateFile -Url "$ManifestUrl.cat" -Destination $catalogPath
    Assert-CaseinUpdateCatalog -ManifestPath $manifestPath -CatalogPath $catalogPath -ExpectedSignerThumbprint $signerThumbprint
    $plan = Read-CaseinUpdatePlan -ManifestPath $manifestPath -Current $current
    if ([string]$plan.Artifact.revision -eq [string]$current.revision) {
        Write-Host "Casein is current on channel $($current.channel)."
        exit 0
    }
    Write-Host "Signed update available: $($current.revision.Substring(0, 7)) -> $(([string]$plan.Artifact.revision).Substring(0, 7))."
    if (-not $Install) { exit 10 }

    Add-Type -AssemblyName System.Windows.Forms
    $choice = [Windows.Forms.MessageBox]::Show(
        'A trusted Casein update is ready. Casein will restart and automatically roll back if health validation fails. Install now?',
        'Casein update',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Information
    )
    if ($choice -ne [Windows.Forms.DialogResult]::Yes) { exit 0 }

    $archive = Join-Path $stage 'casein-update.zip'
    Receive-CaseinUpdateFile -Url ([string]$plan.Artifact.url) -Destination $archive
    if ((Get-Item -LiteralPath $archive).Length -ne [long]$plan.Artifact.size) { throw 'Update archive size mismatch.' }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($actualHash -ne ([string]$plan.Artifact.sha256).ToLowerInvariant()) { throw 'Update archive SHA-256 mismatch.' }

    $expanded = Join-Path $stage 'package'
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded
    $installer = Get-ChildItem -LiteralPath $expanded -Filter 'Install-Casein.ps1' -Recurse |
        Where-Object { $_.FullName.EndsWith('\windows\Install-Casein.ps1', [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
    if (-not $installer) { throw 'Update archive does not contain a Casein Windows installer.' }
    $packageRoot = Split-Path -Parent (Split-Path -Parent $installer.FullName)

    Stop-CaseinTrayForUpdate
    & $installer.FullName -PackageRoot $packageRoot -RequireSigned
    & (Join-Path $InstallRoot 'Casein.Launcher.ps1')
    $settingsPath = Join-Path $env:LOCALAPPDATA 'Casein\desktop-host.json'
    $settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -Raw $settingsPath | ConvertFrom-Json } else { $null }
    $port = if ($settings -and [int]$settings.port -gt 0) { [int]$settings.port } else { 4000 }
    if (-not (Wait-CaseinUpdateHealth -Port $port)) {
        Stop-CaseinTrayForUpdate
        & (Join-Path $InstallRoot 'Rollback-Casein.ps1')
        & (Join-Path $InstallRoot 'Casein.Launcher.ps1')
        throw 'The new release failed health validation and Casein rolled back automatically.'
    }
    Write-Host 'Casein update installed and passed health validation.'
} catch {
    $line = '{0:o} update failed: {1}' -f [DateTime]::UtcNow, $_.Exception.Message
    Add-Content -LiteralPath $updateLog -Value $line -Encoding UTF8
    if ($Install) {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Casein update failed',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    throw
} finally {
    if (Test-Path -LiteralPath $stage) { [IO.Directory]::Delete($stage, $true) }
}
