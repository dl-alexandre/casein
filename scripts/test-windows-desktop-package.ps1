[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [switch]$KeepTestData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$packageRoot = [IO.Path]::GetFullPath($PackageRoot)
$metadataPath = Join-Path $packageRoot 'releases\dev_ide.relmeta.json'
$installer = Join-Path $packageRoot 'windows\Install-DevIDE.ps1'
$uninstaller = Join-Path $packageRoot 'windows\Uninstall-DevIDE.ps1'
$trayHost = Join-Path $packageRoot 'windows\DevIDE.Tray.ps1'

Assert-Condition (Test-Path -LiteralPath $metadataPath) "Release metadata is missing at $metadataPath"
Assert-Condition (Test-Path -LiteralPath $installer) "Installer is missing at $installer"
Assert-Condition (Test-Path -LiteralPath $uninstaller) "Uninstaller is missing at $uninstaller"
Assert-Condition (Test-Path -LiteralPath $trayHost) "Tray host is missing at $trayHost"
Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'docs'))) 'Internal docs must not be included in a public desktop package'

$metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
Assert-Condition ($metadata.profile -eq 'desktop') 'Package profile must be desktop'
Assert-Condition ($metadata.repo_adapter -eq 'sqlite') 'Package repository adapter must be sqlite'
Assert-Condition ($metadata.target -eq 'windows-x86_64') 'Package target must be windows-x86_64'

$originalLocalAppData = $env:LOCALAPPDATA
$testLocalAppData = Join-Path ([IO.Path]::GetTempPath()) ("devide-package-smoke-" + [guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA = $testLocalAppData

try {
    . $trayHost -ReleaseRoot $packageRoot -LibraryOnly
    Initialize-DevIDEJobObjectSupport
    Assert-Condition (($null -ne ('DevIDE.Windows.JobObject' -as [type]))) 'Windows Job Object support did not load'

    New-Item -ItemType Directory -Force -Path $script:Paths.DataRoot | Out-Null
    Set-Content -LiteralPath $script:Paths.RuntimePid -Value '2147483647' -Encoding ascii
    Set-Content -LiteralPath $script:Paths.RuntimeStatus -Value '{"schema":1,"status":"ready"}' -Encoding ascii
    Clear-DevIDEStaleRuntimeState 65534 | Out-Null
    Assert-Condition (-not (Test-Path -LiteralPath $script:Paths.RuntimePid)) 'Stale runtime PID was not cleared'
    Assert-Condition (-not (Test-Path -LiteralPath $script:Paths.RuntimeStatus)) 'Stale runtime status was not cleared'

    $desktopEnvironment = Get-DevIDEEnvironment 54321
    Assert-Condition ($desktopEnvironment.DEVIDE_RELEASE_ROOT -eq $packageRoot) 'Release root was not injected into the desktop runtime'
    $vector = New-DevIDELaunchClaim -Secret 'fixed-desktop-launch-secret-0123456789' -Timestamp 1700000000 -Nonce 'AAECAwQFBgcICQoLDA0ODw'
    Assert-Condition ($vector -eq 'desktop_nonce=AAECAwQFBgcICQoLDA0ODw&desktop_timestamp=1700000000&desktop_proof=VqZtkYtl09-mO3ZBFxIqlavgcmz21EOxoMMqIwYpyg4') 'Windows HMAC claim differs from the shared vector'

    $legacySecretPath = Join-Path $testLocalAppData 'legacy-secret.txt'
    New-Item -ItemType Directory -Force -Path $testLocalAppData | Out-Null
    Set-Content -NoNewline -LiteralPath $legacySecretPath -Value 'legacy-secret-value'
    Assert-Condition ((Get-OrCreateDevIDESecret $legacySecretPath 32) -eq 'legacy-secret-value') 'Legacy secret migration changed the value'
    $protectedSecret = Get-Content -Raw -LiteralPath $legacySecretPath
    Assert-Condition ($protectedSecret.StartsWith('dpapi:')) 'Secret was not protected with DPAPI'
    Assert-Condition (-not $protectedSecret.Contains('legacy-secret-value')) 'Protected secret file contains plaintext'
    Assert-Condition ((Get-OrCreateDevIDESecret $legacySecretPath 32) -eq 'legacy-secret-value') 'DPAPI secret did not round trip'

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -PackageRoot $packageRoot
    if ($LASTEXITCODE -ne 0) { throw "Installer exited with $LASTEXITCODE" }

    $installRoot = Join-Path $testLocalAppData 'Programs\DevIDE'
    $currentPath = Join-Path $installRoot 'current.json'
    Assert-Condition (Test-Path -LiteralPath $currentPath) 'Installer did not write current.json'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $installRoot 'DevIDE.cmd')) 'Installer did not write the stable launcher'
    Assert-Condition (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DevIDE') 'Installer did not register Apps & Features metadata'

    $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
    Assert-Condition (Test-Path -LiteralPath (Join-Path $current.release_root 'bin\dev_ide.bat')) 'Installed release is missing dev_ide.bat'
    Assert-Condition ($current.revision -eq $metadata.revision) 'Installed release revision differs from package metadata'

    $dataRoot = Join-Path $testLocalAppData 'DevIDE'
    New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $dataRoot 'devide.sqlite3') -Value 'desktop-package-smoke' -Encoding ascii
    foreach ($name in @('secret-key-base.txt', 'api-token.txt', 'desktop-launch-token.txt')) {
        Set-Content -LiteralPath (Join-Path $dataRoot $name) -Value 'dpapi:package-smoke-placeholder' -Encoding ascii
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -PackageRoot $packageRoot
    if ($LASTEXITCODE -ne 0) { throw "Upgrade installer exited with $LASTEXITCODE" }

    $backup = Get-ChildItem -LiteralPath (Join-Path $dataRoot 'backups') -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    Assert-Condition ($null -ne $backup) 'Upgrade did not create a data backup'
    Assert-Condition ((Get-Content -Raw -LiteralPath (Join-Path $backup.FullName 'devide.sqlite3')).Trim() -eq 'desktop-package-smoke') 'Upgrade backup did not preserve the database'
    foreach ($name in @('secret-key-base.txt', 'api-token.txt', 'desktop-launch-token.txt')) {
        Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $backup.FullName $name))) "Upgrade backup copied credential $name"
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $uninstaller -RemoveUserData
    if ($LASTEXITCODE -ne 0) { throw "Uninstaller exited with $LASTEXITCODE" }
    Assert-Condition (-not (Test-Path -LiteralPath $installRoot)) 'Uninstaller left the installation root behind'
    Assert-Condition (-not (Test-Path -LiteralPath $dataRoot)) 'Uninstaller left user data behind after -RemoveUserData'
    Assert-Condition (-not (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DevIDE')) 'Uninstaller left Apps & Features metadata behind'

    Write-Host "Windows desktop package smoke passed: $packageRoot"
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (-not $KeepTestData) { Remove-Item -LiteralPath $testLocalAppData -Recurse -Force -ErrorAction SilentlyContinue }
}
