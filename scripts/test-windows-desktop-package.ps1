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

Assert-Condition (Test-Path -LiteralPath $metadataPath) "Release metadata is missing at $metadataPath"
Assert-Condition (Test-Path -LiteralPath $installer) "Installer is missing at $installer"
Assert-Condition (Test-Path -LiteralPath $uninstaller) "Uninstaller is missing at $uninstaller"
Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'docs'))) 'Internal docs must not be included in a public desktop package'

$metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
Assert-Condition ($metadata.profile -eq 'desktop') 'Package profile must be desktop'
Assert-Condition ($metadata.repo_adapter -eq 'sqlite') 'Package repository adapter must be sqlite'
Assert-Condition ($metadata.target -eq 'windows-x86_64') 'Package target must be windows-x86_64'

$originalLocalAppData = $env:LOCALAPPDATA
$testLocalAppData = Join-Path ([IO.Path]::GetTempPath()) ("devide-package-smoke-" + [guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA = $testLocalAppData

try {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -PackageRoot $packageRoot
    if ($LASTEXITCODE -ne 0) { throw "Installer exited with $LASTEXITCODE" }

    $installRoot = Join-Path $testLocalAppData 'Programs\DevIDE'
    $currentPath = Join-Path $installRoot 'current.json'
    Assert-Condition (Test-Path -LiteralPath $currentPath) 'Installer did not write current.json'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $installRoot 'DevIDE.cmd')) 'Installer did not write the stable launcher'

    $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
    Assert-Condition (Test-Path -LiteralPath (Join-Path $current.release_root 'bin\dev_ide.bat')) 'Installed release is missing dev_ide.bat'
    Assert-Condition ($current.revision -eq $metadata.revision) 'Installed release revision differs from package metadata'

    $dataRoot = Join-Path $testLocalAppData 'DevIDE'
    New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $dataRoot 'devide.sqlite3') -Value 'desktop-package-smoke' -Encoding ascii

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -PackageRoot $packageRoot
    if ($LASTEXITCODE -ne 0) { throw "Upgrade installer exited with $LASTEXITCODE" }

    $backup = Get-ChildItem -LiteralPath (Join-Path $dataRoot 'backups') -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    Assert-Condition ($null -ne $backup) 'Upgrade did not create a data backup'
    Assert-Condition ((Get-Content -Raw -LiteralPath (Join-Path $backup.FullName 'devide.sqlite3')).Trim() -eq 'desktop-package-smoke') 'Upgrade backup did not preserve the database'

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $uninstaller -RemoveUserData
    if ($LASTEXITCODE -ne 0) { throw "Uninstaller exited with $LASTEXITCODE" }
    Assert-Condition (-not (Test-Path -LiteralPath $installRoot)) 'Uninstaller left the installation root behind'
    Assert-Condition (-not (Test-Path -LiteralPath $dataRoot)) 'Uninstaller left user data behind after -RemoveUserData'

    Write-Host "Windows desktop package smoke passed: $packageRoot"
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (-not $KeepTestData) { Remove-Item -LiteralPath $testLocalAppData -Recurse -Force -ErrorAction SilentlyContinue }
}
