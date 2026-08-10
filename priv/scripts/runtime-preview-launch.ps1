[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$Port
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Kill-on-close Job Object so every descendant of the preview app dies when
# this launcher exits (normal, crash, or forced). taskkill /T remains a
# belt-and-suspenders fallback when assignment is unavailable.
function Initialize-CaseinPreviewJobObjectSupport {
    if ('Casein.Windows.PreviewJobObject' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Casein.Windows {
    public static class PreviewJobObject {
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimits {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimits {
            public BasicLimits BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(SafeFileHandle job, int infoClass, IntPtr info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);

        public static SafeFileHandle CreateKillOnClose() {
            var job = CreateJobObject(IntPtr.Zero, null);
            if (job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            var limits = new ExtendedLimits();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(limits);
            IntPtr pointer = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(limits, pointer, false);
                if (!SetInformationJobObject(job, 9, pointer, (uint)size))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { Marshal.FreeHGlobal(pointer); }
            return job;
        }

        public static void Assign(SafeFileHandle job, IntPtr processHandle) {
            if (!AssignProcessToJobObject(job, processHandle))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@
}

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
        process_tree = 'job_object_kill_on_close'
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

function Stop-PreviewProcessTree {
    param(
        [System.Diagnostics.Process]$Process,
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$Job
    )

    # Disposing the kill-on-close job reaps the entire tree first.
    if ($null -ne $Job -and -not $Job.IsInvalid -and -not $Job.IsClosed) {
        try { $Job.Dispose() } catch { }
    }

    if ($null -eq $Process) { return }

    try {
        if (-not $Process.HasExited) {
            & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null
        }
    } catch {
        # best effort
    }

    try { $Process.Dispose() } catch { }
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

$previewJob = $null
$process = $null

try {
    Initialize-CaseinPreviewJobObjectSupport
    $previewJob = [Casein.Windows.PreviewJobObject]::CreateKillOnClose()
} catch {
    Add-Content -LiteralPath $logPath -Value "warning: Job Object unavailable ($($_.Exception.Message)); falling back to taskkill /T"
    $previewJob = $null
}

try {
    $process = Start-Process -FilePath $command.File -ArgumentList $command.Args -WorkingDirectory $cwd `
        -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.error" -PassThru -WindowStyle Hidden

    if ($null -ne $previewJob) {
        try {
            [Casein.Windows.PreviewJobObject]::Assign($previewJob, $process.Handle)
            Add-Content -LiteralPath $logPath -Value ">>> process_tree=job_object_kill_on_close pid=$($process.Id)"
        } catch {
            Add-Content -LiteralPath $logPath -Value "warning: Job Object assign failed ($($_.Exception.Message)); using taskkill /T on exit"
            try { $previewJob.Dispose() } catch { }
            $previewJob = $null
        }
    }

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
    Stop-PreviewProcessTree -Process $process -Job $previewJob
}
