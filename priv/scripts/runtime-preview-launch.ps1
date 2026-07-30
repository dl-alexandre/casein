[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$Port
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-LoopbackPort {
    param([int]$TargetPort, [int]$TimeoutMs = 250)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $result = $client.BeginConnect('127.0.0.1', $TargetPort, $null, $null)
        if (-not $result.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($result)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Write-PreviewRegistry {
    param([string]$Status, [int]$ProcessId)
    $payload = [ordered]@{
        id = $runtimeId
        kind = 'runtime'
        ref = 'runtime'
        sha = [string]$env:SOURCE_REVISION
        port = $Port
        socket = ''
        pid = $ProcessId
        proxy_pid = $null
        db = ''
        worktree = $cwd
        checkout = $cwd
        workspaces_root = ''
        log = $logPath
        started_at = [DateTime]::UtcNow.ToString('o')
        status = $Status
        workspace_id = [string]$env:CASEIN_WORKSPACE_ID
        runtime_id = $runtimeId
        tmux_session_id = [string]$env:CASEIN_TMUX_SESSION
        url = "http://127.0.0.1:$Port/"
    }
    $temporary = "$registryPath.$PID.tmp"
    $json = $payload | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $registryPath -Force
}

function Resolve-PreviewCommand {
    if ($env:CASEIN_RUNTIME_PREVIEW_COMMAND) {
        return @{ File = 'powershell.exe'; Args = @('-NoProfile', '-Command', $env:CASEIN_RUNTIME_PREVIEW_COMMAND) }
    }
    if (Test-Path -LiteralPath (Join-Path $cwd 'mix.exs')) {
        $mise = Get-Command mise.exe -ErrorAction SilentlyContinue
        if ($mise) { return @{ File = $mise.Source; Args = @('exec', '--', 'mix', 'phx.server') } }
        $mix = Get-Command mix.bat -ErrorAction SilentlyContinue
        if ($mix) { return @{ File = $mix.Source; Args = @('phx.server') } }
        throw 'No supported Elixir launcher was found. Install mise or make mix.bat available on PATH.'
    }
    if (Test-Path -LiteralPath (Join-Path $cwd 'package.json')) {
        $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if ($npm) { return @{ File = $npm.Source; Args = @('run', 'dev', '--', '--host', '127.0.0.1', '--port', [string]$Port) } }
        throw 'package.json was found, but npm.cmd is not available on PATH.'
    }
    throw "No supported preview command was detected in $cwd."
}

$cwd = [IO.Path]::GetFullPath((Get-Location).Path)
$runtimeId = if ($env:CASEIN_RUNTIME_ID) { $env:CASEIN_RUNTIME_ID } else { "runtime-$PID" }
$previewHome = if ($env:CASEIN_PREVIEW_HOME) { $env:CASEIN_PREVIEW_HOME } else { Join-Path $cwd '.casein-preview' }
$instances = Join-Path $previewHome 'instances'
$logs = Join-Path $previewHome 'logs'
$registryPath = Join-Path $instances "$runtimeId.json"
$logPath = Join-Path $logs "$runtimeId.log"
New-Item -ItemType Directory -Force -Path $instances, $logs | Out-Null

if (Test-LoopbackPort -TargetPort $Port) {
    Add-Content -LiteralPath $logPath -Value "error: runtime preview port 127.0.0.1:$Port is already in use"
    Write-PreviewRegistry -Status 'failed' -ProcessId $PID
    exit 1
}

$command = Resolve-PreviewCommand
Add-Content -LiteralPath $logPath -Value ">>> runtime preview cwd=$cwd port=$Port"
Add-Content -LiteralPath $logPath -Value ">>> command=$($command.File) $($command.Args -join ' ')"

$process = Start-Process -FilePath $command.File -ArgumentList $command.Args -WorkingDirectory $cwd `
    -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.error" -PassThru -WindowStyle Hidden

try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        if ($process.HasExited) { break }
        if (Test-LoopbackPort -TargetPort $Port) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) {
        Write-PreviewRegistry -Status 'failed' -ProcessId $process.Id
        throw "Preview process did not answer on 127.0.0.1:$Port. See $logPath and $logPath.error."
    }
    Write-PreviewRegistry -Status 'running' -ProcessId $process.Id
    $process.WaitForExit()
    exit $process.ExitCode
} finally {
    if (-not $process.HasExited) {
        & taskkill.exe /PID $process.Id /T /F | Out-Null
    }
}
