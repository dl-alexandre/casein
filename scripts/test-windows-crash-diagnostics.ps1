[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'This smoke requires Windows PowerShell 5.1.' }

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $env:TEMP ('casein-crash-diagnostics-' + [Guid]::NewGuid().ToString('N'))
$previousDataRoot = $env:CASEIN_DESKTOP_DATA_DIR
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $env:CASEIN_DESKTOP_DATA_DIR = $testRoot
    . (Join-Path $root 'windows\Casein.Tray.ps1') -ReleaseRoot $root -LibraryOnly

    Set-Content -LiteralPath $script:Paths.RuntimePid -Value '2147483647' -Encoding ascii
    if (-not (Observe-CaseinRuntimeFailure)) { throw 'Stopped runtime was not observed.' }
    $observed = Get-Content -Raw -LiteralPath $script:Paths.CrashState | ConvertFrom-Json
    if ([int]$observed.runtime_pid -ne 2147483647 -or $observed.recovery_status -ne 'detected') {
        throw 'Observed runtime failure was not recorded.'
    }
    Remove-Item -LiteralPath $script:Paths.RuntimePid -Force

    Write-CaseinCrashState -RuntimePid 4242 -ExitCode 23 -RecoveryStatus 'detected'
    Update-CaseinRecoveryState -RecoveryStatus 'recovering' -RecoveryAttempts 2
    Update-CaseinRecoveryState -RecoveryStatus 'recovered' -RecoveryAttempts 2
    $state = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'crash-state.json') | ConvertFrom-Json
    if ([int]$state.runtime_pid -ne 4242) { throw 'Runtime PID was not recorded.' }
    if ([int]$state.exit_code -ne 23) { throw 'Runtime exit code was not recorded.' }
    if ([int]$state.recovery_attempts -ne 2 -or $state.recovery_status -ne 'recovered') {
        throw 'Recovery outcome was not recorded.'
    }
    if (-not $state.recovered_at_utc) { throw 'Recovery timestamp was not recorded.' }

    $state | Add-Member -NotePropertyName injected_secret -NotePropertyValue 'must-not-ship'
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'crash-state.json') -Encoding UTF8
    $archive = Join-Path $testRoot 'support.zip'
    $expanded = Join-Path $testRoot 'support-expanded'
    & (Join-Path $root 'windows\New-CaseinSupportBundle.ps1') `
        -DataRoot $testRoot `
        -InstallRoot (Join-Path $testRoot 'install') `
        -Destination $archive | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded
    $bundledStateText = Get-Content -Raw -LiteralPath (Join-Path $expanded 'crash-state.json')
    if ($bundledStateText.Contains('must-not-ship')) { throw 'Support bundle copied an untrusted crash-state field.' }
    $bundledState = $bundledStateText | ConvertFrom-Json
    if ($bundledState.recovery_status -ne 'recovered') { throw 'Support bundle omitted recovery status.' }

    $state.detected_at_utc = 'must-not-ship'
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'crash-state.json') -Encoding UTF8
    $invalidArchive = Join-Path $testRoot 'support-invalid.zip'
    $invalidExpanded = Join-Path $testRoot 'support-invalid-expanded'
    & (Join-Path $root 'windows\New-CaseinSupportBundle.ps1') `
        -DataRoot $testRoot `
        -InstallRoot (Join-Path $testRoot 'install') `
        -Destination $invalidArchive | Out-Null
    Expand-Archive -LiteralPath $invalidArchive -DestinationPath $invalidExpanded
    if (-not (Test-Path -LiteralPath (Join-Path $invalidExpanded 'crash-state-invalid.txt'))) {
        throw 'Invalid crash state was not replaced with a safe marker.'
    }
    if (Test-Path -LiteralPath (Join-Path $invalidExpanded 'crash-state.json')) {
        throw 'Invalid crash state was included in the support bundle.'
    }

    Write-Host 'Windows crash diagnostics and support redaction smoke passed.'
} finally {
    if ($null -eq $previousDataRoot) {
        Remove-Item Env:CASEIN_DESKTOP_DATA_DIR -ErrorAction SilentlyContinue
    } else {
        $env:CASEIN_DESKTOP_DATA_DIR = $previousDataRoot
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
