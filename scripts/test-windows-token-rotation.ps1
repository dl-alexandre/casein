[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'This smoke requires Windows PowerShell 5.1.' }

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $env:TEMP ('casein-token-rotation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    . (Join-Path $root 'windows\Casein.Tray.ps1') -ReleaseRoot $root -LibraryOnly
    $apiPath = Join-Path $testRoot 'api-token.txt'
    $launchPath = Join-Path $testRoot 'desktop-launch-token.txt'
    $oldApi = Get-OrCreateCaseinSecret $apiPath 48
    $oldLaunch = Get-OrCreateCaseinSecret $launchPath 48

    Invoke-CaseinAccessTokenRotation -DataRoot $testRoot -Validate { $true }
    if ((Get-OrCreateCaseinSecret $apiPath 48) -eq $oldApi) { throw 'API token did not rotate.' }
    if ((Get-OrCreateCaseinSecret $launchPath 48) -eq $oldLaunch) { throw 'Launch token did not rotate.' }

    $apiCiphertext = Get-Content -Raw -LiteralPath $apiPath
    $launchCiphertext = Get-Content -Raw -LiteralPath $launchPath
    $script:recoveryCalled = $false
    try {
        Invoke-CaseinAccessTokenRotation -DataRoot $testRoot -Validate { $false } -Recover { $script:recoveryCalled = $true }
        throw 'Failed health validation was accepted.'
    } catch {
        if (-not $_.Exception.Message.Contains('did not become healthy')) { throw }
    }
    if (-not $script:recoveryCalled) { throw 'Recovery callback was not invoked.' }
    if ((Get-Content -Raw -LiteralPath $apiPath) -ne $apiCiphertext) { throw 'API token ciphertext was not restored.' }
    if ((Get-Content -Raw -LiteralPath $launchPath) -ne $launchCiphertext) { throw 'Launch token ciphertext was not restored.' }

    $statePath = Join-Path $testRoot 'credential-state.json'
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $state | Add-Member -NotePropertyName injected_secret -NotePropertyValue 'must-not-ship'
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    $archive = Join-Path $testRoot 'support.zip'
    $expanded = Join-Path $testRoot 'support-expanded'
    & (Join-Path $root 'windows\New-CaseinSupportBundle.ps1') `
        -DataRoot $testRoot `
        -InstallRoot (Join-Path $testRoot 'install') `
        -Destination $archive | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded
    $bundledState = Get-Content -Raw -LiteralPath (Join-Path $expanded 'credential-state.json')
    if ($bundledState.Contains('must-not-ship')) { throw 'Support bundle copied an untrusted state field.' }
    if (Test-Path -LiteralPath (Join-Path $expanded 'api-token.txt')) { throw 'Support bundle copied the API token file.' }
    if (Test-Path -LiteralPath (Join-Path $expanded 'desktop-launch-token.txt')) { throw 'Support bundle copied the launch token file.' }

    Write-Host 'Windows token rotation, rollback, and support redaction smoke passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
