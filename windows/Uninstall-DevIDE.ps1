[CmdletBinding()]
param(
    [switch]$RemoveUserData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\DevIDE'
$dataRoot = Join-Path $env:LOCALAPPDATA 'DevIDE'
$pidPath = Join-Path $dataRoot 'runtime.pid'

if (Test-Path -LiteralPath $pidPath) {
    $runtimePid = 0
    [void][int]::TryParse((Get-Content -Raw -LiteralPath $pidPath).Trim(), [ref]$runtimePid)
    if ($runtimePid -gt 0 -and (Get-Process -Id $runtimePid -ErrorAction SilentlyContinue)) {
        & taskkill.exe /PID $runtimePid /T /F *> $null
    }
}

Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DevIDE' -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveUserData) { Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host 'Casein was uninstalled.'
