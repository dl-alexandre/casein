[CmdletBinding()]
param(
    [switch]$RemoveUserData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Casein'
$dataRoot = Join-Path $env:LOCALAPPDATA 'Casein'
$pidPath = Join-Path $dataRoot 'runtime.pid'
$trustedLanState = Join-Path $dataRoot 'trusted-lan.json'

if (Test-Path -LiteralPath $pidPath) {
    $runtimePid = 0
    [void][int]::TryParse((Get-Content -Raw -LiteralPath $pidPath).Trim(), [ref]$runtimePid)
    if ($runtimePid -gt 0 -and (Get-Process -Id $runtimePid -ErrorAction SilentlyContinue)) {
        & taskkill.exe /PID $runtimePid /T /F *> $null
    }
}

if (Test-Path -LiteralPath $trustedLanState) {
    $lanState = Get-Content -Raw -LiteralPath $trustedLanState | ConvertFrom-Json
    $trustedLanHelper = $null
    $currentPath = Join-Path $installRoot 'current.json'
    if ([bool]$lanState.enabled -and (Test-Path -LiteralPath $currentPath)) {
        $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
        $candidate = Join-Path ([string]$current.release_root) 'windows\Casein.TrustedLan.ps1'
        if (Test-Path -LiteralPath $candidate) { $trustedLanHelper = Get-Item -LiteralPath $candidate }
    }
    if ($trustedLanHelper) {
        $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$($trustedLanHelper.FullName)`" -Action Disable -DataRoot `"$dataRoot`" -ReleaseRoot `"$([string]$current.release_root)`""
        $cleanup = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        if ($cleanup.ExitCode -ne 0) {
            throw 'Casein was not uninstalled because its Trusted LAN firewall rule could not be removed.'
        }
    } elseif ([bool]$lanState.enabled) {
        throw 'Casein was not uninstalled because the Trusted LAN cleanup helper is missing.'
    }
}

Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Casein' -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveUserData) { Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host 'Casein was uninstalled.'
