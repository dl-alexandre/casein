[CmdletBinding()]
param(
    [string]$ReleaseRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function Get-DevIDEPaths {
    param([string]$Root)

    $dataRoot = if ($env:CASEIN_DESKTOP_DATA_DIR) {
        $env:CASEIN_DESKTOP_DATA_DIR
    } else {
        Join-Path $env:LOCALAPPDATA 'DevIDE'
    }

    [pscustomobject]@{
        ReleaseRoot = [IO.Path]::GetFullPath($Root)
        ReleaseBat  = Join-Path $Root 'bin\casein.bat'
        DataRoot    = $dataRoot
        Database    = Join-Path $dataRoot 'devide.sqlite3'
        Settings    = Join-Path $dataRoot 'desktop-host.json'
        Log         = Join-Path $dataRoot 'desktop-host.log'
        RuntimePid  = Join-Path $dataRoot 'runtime.pid'
        RuntimeStatus = Join-Path $dataRoot 'runtime.json'
        RuntimeTemp = Join-Path $dataRoot 'runtime-tmp'
        StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'DevIDE.lnk'
    }
}

function Write-DevIDELog {
    param([string]$Message)

    $maxBytes = 2MB
    $rotated = "$($script:Paths.Log).1"
    if ((Test-Path -LiteralPath $script:Paths.Log) -and (Get-Item -LiteralPath $script:Paths.Log).Length -ge $maxBytes) {
        Move-Item -LiteralPath $script:Paths.Log -Destination $rotated -Force
    }

    $line = '{0:o} {1}' -f [DateTime]::UtcNow, $Message
    Add-Content -LiteralPath $script:Paths.Log -Value $line -Encoding UTF8
}

function Open-DevIDECockpit {
    param([int]$Port)

    if (-not (Test-DevIDEReady $Port)) { return $false }
    $token = Get-OrCreateDevIDESecret (Join-Path $script:Paths.DataRoot 'desktop-launch-token.txt') 48
    $claim = New-DevIDELaunchClaim $token
    Start-Process "http://127.0.0.1:$Port/?$claim"
    return $true
}

function ConvertTo-DevIDEBase64Url {
    param([byte[]]$Bytes)

    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-DevIDELaunchClaim {
    param([string]$Secret, [long]$Timestamp = 0, [string]$Nonce = '')

    if (-not $Nonce) {
        $nonceBytes = New-Object byte[] 16
        $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $generator.GetBytes($nonceBytes)
        } finally {
            $generator.Dispose()
        }
        $Nonce = ConvertTo-DevIDEBase64Url $nonceBytes
    }

    if ($Timestamp -eq 0) { $Timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    $message = [Text.Encoding]::UTF8.GetBytes("v1.$Timestamp.$Nonce")
    $hmac = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        $proof = ConvertTo-DevIDEBase64Url ($hmac.ComputeHash($message))
    } finally {
        $hmac.Dispose()
    }

    return ('desktop_nonce={0}&desktop_timestamp={1}&desktop_proof={2}' -f [Uri]::EscapeDataString($Nonce), $Timestamp, [Uri]::EscapeDataString($proof))
}

function Get-FreeLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Test-DevIDEPortAvailable {
    param([int]$Port)

    try {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

function Read-DevIDESettings {
    $defaults = [ordered]@{ port = 0; launchAtSignIn = $false }
    if (-not (Test-Path -LiteralPath $script:Paths.Settings)) {
        return [pscustomobject]$defaults
    }

    try {
        $saved = Get-Content -Raw -LiteralPath $script:Paths.Settings | ConvertFrom-Json
        if ($saved.port -as [int]) { $defaults.port = [int]$saved.port }
        $defaults.launchAtSignIn = [bool]$saved.launchAtSignIn
    } catch {
        Write-DevIDELog "Ignoring invalid settings: $($_.Exception.Message)"
    }

    [pscustomobject]$defaults
}

function Save-DevIDESettings {
    param([int]$Port, [bool]$LaunchAtSignIn)

    [ordered]@{ port = $Port; launchAtSignIn = $LaunchAtSignIn } |
        ConvertTo-Json |
        Set-Content -LiteralPath $script:Paths.Settings -Encoding UTF8
}

function Get-DevIDEPort {
    param([int]$SavedPort)

    if ($SavedPort -ge 1024 -and $SavedPort -le 65535) {
        if ((Test-DevIDEReady $SavedPort) -or (Test-DevIDEPortAvailable $SavedPort)) {
            return $SavedPort
        }
    }

    Get-FreeLoopbackPort
}

function Get-OrCreateDevIDESecret {
    param([string]$Path, [int]$Bytes)

    if (-not (Test-Path -LiteralPath $Path)) {
        $buffer = New-Object byte[] $Bytes
        $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $generator.GetBytes($buffer)
        } finally {
            $generator.Dispose()
        }
        $secret = [Convert]::ToBase64String($buffer)
        Save-DevIDEProtectedSecret $Path $secret
        return $secret
    }

    $stored = (Get-Content -Raw -LiteralPath $Path).Trim()
    if ($stored.StartsWith('dpapi:')) {
        $protected = [Convert]::FromBase64String($stored.Substring(6))
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($plain)
    }

    # One-time migration from the original plaintext file format. Replace the
    # file before returning so update backups never replicate reusable roots.
    Save-DevIDEProtectedSecret $Path $stored
    return $stored
}

function Save-DevIDEProtectedSecret {
    param([string]$Path, [string]$Secret)

    $plain = [Text.Encoding]::UTF8.GetBytes($Secret)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $plain, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $encoded = 'dpapi:' + [Convert]::ToBase64String($protected)
    $temporary = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($temporary, $encoded)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-DevIDEEnvironment {
    param([int]$Port)

    $secret = Get-OrCreateDevIDESecret (Join-Path $script:Paths.DataRoot 'secret-key-base.txt') 64
    $apiToken = Get-OrCreateDevIDESecret (Join-Path $script:Paths.DataRoot 'api-token.txt') 48
    $launchToken = Get-OrCreateDevIDESecret (Join-Path $script:Paths.DataRoot 'desktop-launch-token.txt') 48
    New-Item -ItemType Directory -Force -Path $script:Paths.RuntimeTemp | Out-Null

    @{
        'CASEIN_PROFILE' = 'desktop'
        'CASEIN_DESKTOP_DATA_DIR' = $script:Paths.DataRoot
        'DEVIDE_RELEASE_ROOT' = $script:Paths.ReleaseRoot
        'CASEIN_REPO_ADAPTER' = 'sqlite'
        'DATABASE_PATH' = $script:Paths.Database
        'PHX_SERVER' = 'true'
        'PHX_HOST' = 'localhost'
        'PHX_IP' = '127.0.0.1'
        'PORT' = [string]$Port
        'RELEASE_NODE' = 'dev_ide_desktop'
        # The desktop host owns lifecycle locally. Never publish a BEAM node or
        # reuse the build-time COOKIE across machines.
        'RELEASE_DISTRIBUTION' = 'none'
        'RELEASE_TMP' = $script:Paths.RuntimeTemp
        'SECRET_KEY_BASE' = $secret
        'CASEIN_API_TOKEN' = $apiToken
        'CASEIN_DESKTOP_LAUNCH_TOKEN' = $launchToken
    }
}

function Initialize-DevIDEJobObjectSupport {
    if ('DevIDE.Windows.JobObject' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace DevIDE.Windows {
    public static class JobObject {
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

function Get-DevIDERuntimePid {
    if (-not (Test-Path -LiteralPath $script:Paths.RuntimePid)) { return 0 }
    $runtimePid = 0
    [void][int]::TryParse((Get-Content -Raw -LiteralPath $script:Paths.RuntimePid).Trim(), [ref]$runtimePid)
    return $runtimePid
}

function Test-DevIDEProcessAlive {
    param([int]$RuntimePid)
    if ($RuntimePid -le 0) { return $false }
    return $null -ne (Get-Process -Id $RuntimePid -ErrorAction SilentlyContinue)
}

function Clear-DevIDEStaleRuntimeState {
    param([int]$Port)

    $runtimePid = Get-DevIDERuntimePid
    if (Test-DevIDEReady $Port) { return $true }

    if (-not (Test-DevIDEProcessAlive $runtimePid)) {
        if ($runtimePid -gt 0 -or (Test-Path -LiteralPath $script:Paths.RuntimeStatus)) {
            Write-DevIDELog "Removing stale desktop runtime state for process $runtimePid"
        }
        Remove-Item -LiteralPath $script:Paths.RuntimePid -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Paths.RuntimeStatus -Force -ErrorAction SilentlyContinue
    }
    return $false
}

function Invoke-DevIDERelease {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$Port,
        [switch]$Wait
    )

    if (-not (Test-Path -LiteralPath $script:Paths.ReleaseBat)) {
        throw "DevIDE release not found at $($script:Paths.ReleaseBat)"
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $startInfo.WorkingDirectory = $script:Paths.ReleaseRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.Arguments = '/d /s /c ""{0}" {1}"' -f $script:Paths.ReleaseBat, ($Arguments -join ' ')
    foreach ($entry in (Get-DevIDEEnvironment $Port).GetEnumerator()) {
        $startInfo.EnvironmentVariables[$entry.Key] = $entry.Value
    }

    $process = [Diagnostics.Process]::Start($startInfo)
    if ($Wait) {
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Release command '$($Arguments -join ' ')' exited with $($process.ExitCode)"
        }
    }
    $process
}

function Test-DevIDEReady {
    param([int]$Port)

    try {
        $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 -Uri "http://127.0.0.1:$Port/healthz"
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Wait-DevIDEReady {
    param([int]$Port, [int]$TimeoutSeconds = 45)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-DevIDEReady $Port) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Start-DevIDERuntime {
    param([int]$Port)

    if (Clear-DevIDEStaleRuntimeState $Port) { return $true }
    Write-DevIDELog "Starting desktop runtime on 127.0.0.1:$Port"
    Invoke-DevIDERelease -Arguments @('eval', 'DevIDE.Release.migrate()') -Port $Port -Wait | Out-Null
    # On Windows the release `start` command remains attached to the daemon it
    # launches. Waiting for that command therefore waits until DevIDE stops and
    # then misreports the shutdown exit code as a startup failure.
    $runtime = Invoke-DevIDERelease -Arguments @('start') -Port $Port
    if ($script:RuntimeJob) { $script:RuntimeJob.Dispose() }
    $script:RuntimeJob = [DevIDE.Windows.JobObject]::CreateKillOnClose()
    [DevIDE.Windows.JobObject]::Assign($script:RuntimeJob, $runtime.Handle)
    Set-Content -LiteralPath $script:Paths.RuntimePid -Value $runtime.Id -Encoding ascii
    $ready = Wait-DevIDEReady $Port
    if (-not $ready) { Stop-DevIDERuntime $Port }
    Write-DevIDELog "Runtime ready: $ready"
    $ready
}

function Stop-DevIDERuntime {
    param([int]$Port)

    if (-not (Test-Path -LiteralPath $script:Paths.RuntimePid)) {
        if (Test-DevIDEReady $Port) {
            Write-DevIDELog 'Runtime is healthy but was not started by this tray host; leaving it untouched'
        }
        if ($script:RuntimeJob) {
            $script:RuntimeJob.Dispose()
            $script:RuntimeJob = $null
        }
        return
    }

    $runtimePid = Get-DevIDERuntimePid
    Remove-Item -LiteralPath $script:Paths.RuntimePid -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:Paths.RuntimeStatus -Force -ErrorAction SilentlyContinue
    if ($runtimePid -le 0) {
        if ($script:RuntimeJob) {
            $script:RuntimeJob.Dispose()
            $script:RuntimeJob = $null
        }
        return
    }

    Write-DevIDELog "Stopping desktop runtime process tree $runtimePid"
    & taskkill.exe /PID $runtimePid /T /F *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-DevIDELog "Runtime process tree $runtimePid was already stopped or could not be terminated"
    }
    if ($script:RuntimeJob) {
        $script:RuntimeJob.Dispose()
        $script:RuntimeJob = $null
    }
}

function Set-DevIDEStartup {
    param([bool]$Enabled)

    if ($Enabled) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($script:Paths.StartupLink)
        $shortcut.TargetPath = (Get-Command powershell.exe).Source
        $escapedScript = $PSCommandPath.Replace('"', '""')
        $escapedRoot = $script:Paths.ReleaseRoot.Replace('"', '""')
        $shortcut.Arguments = "-NoLogo -NoProfile -WindowStyle Hidden -File `"$escapedScript`" -ReleaseRoot `"$escapedRoot`""
        $shortcut.WorkingDirectory = $script:Paths.ReleaseRoot
        $shortcut.Description = 'Start Casein in the Windows notification area'
        $shortcut.Save()
    } else {
        Remove-Item -LiteralPath $script:Paths.StartupLink -Force -ErrorAction SilentlyContinue
    }
}

function New-DevIDEIcon {
    param([Drawing.Color]$StatusColor)

    $sourcePath = Join-Path $PSScriptRoot 'DevIDE.png'
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        $sourcePath = Join-Path $PSScriptRoot '..\priv\static\images\pwa-icon-192.png'
    }
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "DevIDE tray icon asset is missing"
    }

    $source = [Drawing.Image]::FromFile($sourcePath)
    $bitmap = [Drawing.Bitmap]::new(32, 32, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([Drawing.Color]::Transparent)
    $statusBrush = [Drawing.SolidBrush]::new($StatusColor)
    $badgeOutline = [Drawing.Pen]::new([Drawing.Color]::FromArgb(235, 16, 17, 20), 2)
    try {
        $graphics.DrawImage($source, [Drawing.Rectangle]::new(0, 0, 32, 32))
        $graphics.FillEllipse($statusBrush, 23, 23, 8, 8)
        $graphics.DrawEllipse($badgeOutline, 23, 23, 8, 8)
        return [Drawing.Icon]::FromHandle($bitmap.GetHicon())
    } finally {
        $badgeOutline.Dispose()
        $statusBrush.Dispose()
        $graphics.Dispose()
        $source.Dispose()
        # Keep the bitmap alive because the icon owns its native handle for the tray lifetime.
        $script:IconBitmaps.Add($bitmap)
    }
}

function Start-DevIDETray {
    $createdNew = $false
    $script:InstanceMutex = New-Object Threading.Mutex($true, 'Local\DevIDE.Desktop.Tray', [ref]$createdNew)
    if (-not $createdNew) {
        $script:InstanceMutex.Dispose()
        $settings = Read-DevIDESettings
        if (Open-DevIDECockpit $settings.port) {
            Write-DevIDELog 'Opened the already-running DevIDE cockpit from a second launch'
        }
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    Initialize-DevIDEJobObjectSupport

    $script:IconBitmaps = [Collections.Generic.List[Drawing.Bitmap]]::new()
    $settings = Read-DevIDESettings
    $script:Port = Get-DevIDEPort $settings.port
    $script:LaunchAtSignIn = [bool]$settings.launchAtSignIn
    $script:RecoveryAttempts = 0
    $script:NextRecoveryAt = [DateTime]::MinValue
    Save-DevIDESettings $script:Port $script:LaunchAtSignIn

    $runningIcon = New-DevIDEIcon ([Drawing.Color]::FromArgb(34, 197, 94))
    $stoppedIcon = New-DevIDEIcon ([Drawing.Color]::FromArgb(107, 114, 128))
    $errorIcon = New-DevIDEIcon ([Drawing.Color]::FromArgb(239, 68, 68))

    $tray = [Windows.Forms.NotifyIcon]::new()
    $tray.Text = 'Casein is starting'
    $tray.Icon = $stoppedIcon
    $tray.Visible = $true

    $menu = [Windows.Forms.ContextMenuStrip]::new()
    $statusItem = $menu.Items.Add('Starting...')
    $statusItem.Enabled = $false
    [void]$menu.Items.Add('-')
    $openItem = $menu.Items.Add('Open Casein')
    $restartItem = $menu.Items.Add('Restart')
    $repairItem = $menu.Items.Add('Repair installation')
    $rollbackItem = $menu.Items.Add('Roll back last update')
    $logsItem = $menu.Items.Add('Open logs')
    $supportItem = $menu.Items.Add('Create support bundle')
    $startupItem = $menu.Items.Add('Launch at Windows sign-in')
    $startupItem.Checked = $script:LaunchAtSignIn
    [void]$menu.Items.Add('-')
    $quitItem = $menu.Items.Add('Quit Casein')
    $tray.ContextMenuStrip = $menu

    $open = {
        if (-not (Open-DevIDECockpit $script:Port)) {
            $tray.ShowBalloonTip(3000, 'Casein', 'Casein is not ready yet.', [Windows.Forms.ToolTipIcon]::Info)
        }
    }
    $openItem.Add_Click($open)
    $tray.Add_DoubleClick($open)
    $logsItem.Add_Click({
        if (Test-Path -LiteralPath $script:Paths.Log) {
            Start-Process notepad.exe -ArgumentList @($script:Paths.Log)
        } else {
            Start-Process explorer.exe -ArgumentList @($script:Paths.DataRoot)
        }
    })
    $startupItem.Add_Click({
        $script:LaunchAtSignIn = -not $script:LaunchAtSignIn
        Set-DevIDEStartup $script:LaunchAtSignIn
        $startupItem.Checked = $script:LaunchAtSignIn
        Save-DevIDESettings $script:Port $script:LaunchAtSignIn
    })
    $restartItem.Add_Click({
        $restartItem.Enabled = $false
        Stop-DevIDERuntime $script:Port
        $ready = Start-DevIDERuntime $script:Port
        $restartItem.Enabled = $true
        if (-not $ready) {
            $tray.ShowBalloonTip(5000, 'Casein failed to start', "Open logs for details.", [Windows.Forms.ToolTipIcon]::Error)
        }
    })
    $repairItem.Add_Click({
        $repairItem.Enabled = $false
        try {
            Stop-DevIDERuntime $script:Port
            & (Join-Path $script:Paths.ReleaseRoot 'windows\Repair-DevIDE.ps1') -InstallRoot (Join-Path $env:LOCALAPPDATA 'Programs\DevIDE')
            if (-not (Start-DevIDERuntime $script:Port)) { throw 'Runtime did not become ready after repair.' }
            $tray.ShowBalloonTip(3000, 'Casein repaired', 'The local database and runtime state are healthy.', [Windows.Forms.ToolTipIcon]::Info)
        } catch {
            Write-DevIDELog "Repair failed: $($_.Exception.Message)"
            $tray.ShowBalloonTip(5000, 'Casein repair failed', 'Open logs for details.', [Windows.Forms.ToolTipIcon]::Error)
        } finally {
            $repairItem.Enabled = $true
        }
    })
    $rollbackItem.Add_Click({
        try {
            Stop-DevIDERuntime $script:Port
            & (Join-Path $script:Paths.ReleaseRoot 'windows\Rollback-DevIDE.ps1') -InstallRoot (Join-Path $env:LOCALAPPDATA 'Programs\DevIDE')
            & (Join-Path $env:LOCALAPPDATA 'Programs\DevIDE\DevIDE.Launcher.ps1')
            $tray.Visible = $false
            [Windows.Forms.Application]::Exit()
        } catch {
            Write-DevIDELog "Rollback failed: $($_.Exception.Message)"
            $tray.ShowBalloonTip(5000, 'Casein rollback failed', $_.Exception.Message, [Windows.Forms.ToolTipIcon]::Error)
        }
    })
    $supportItem.Add_Click({
        try {
            $bundle = & (Join-Path $script:Paths.ReleaseRoot 'windows\New-DevIDESupportBundle.ps1')
            Start-Process explorer.exe -ArgumentList @('/select,', $bundle)
            $tray.ShowBalloonTip(3000, 'Support bundle created', 'The redacted bundle is ready on your Desktop.', [Windows.Forms.ToolTipIcon]::Info)
        } catch {
            Write-DevIDELog "Support bundle failed: $($_.Exception.Message)"
            $tray.ShowBalloonTip(5000, 'Support bundle failed', 'Open logs for details.', [Windows.Forms.ToolTipIcon]::Error)
        }
    })
    $quitItem.Add_Click({
        $timer.Stop()
        Stop-DevIDERuntime $script:Port
        $tray.Visible = $false
        [Windows.Forms.Application]::Exit()
    })

    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 2000
    $timer.Add_Tick({
        if (Test-DevIDEReady $script:Port) {
            $statusItem.Text = 'Running'
            $tray.Text = 'Casein - Running'
            $tray.Icon = $runningIcon
            $openItem.Enabled = $true
            $script:RecoveryAttempts = 0
        } else {
            $statusItem.Text = 'Stopped'
            $tray.Text = 'Casein - Stopped'
            $tray.Icon = $errorIcon
            $openItem.Enabled = $false
            Clear-DevIDEStaleRuntimeState $script:Port | Out-Null

            if ($script:RecoveryAttempts -lt 3 -and [DateTime]::UtcNow -ge $script:NextRecoveryAt) {
                $script:RecoveryAttempts++
                $delaySeconds = [Math]::Pow(2, $script:RecoveryAttempts)
                $script:NextRecoveryAt = [DateTime]::UtcNow.AddSeconds($delaySeconds)
                $statusItem.Text = "Recovering ($($script:RecoveryAttempts)/3)"
                Write-DevIDELog "Attempting automatic runtime recovery $($script:RecoveryAttempts)/3"
                if (Start-DevIDERuntime $script:Port) { $script:RecoveryAttempts = 0 }
            }
        }
    })
    $timer.Start()

    try {
        if (Start-DevIDERuntime $script:Port) {
            $tray.Icon = $runningIcon
            $tray.Text = 'Casein - Running'
            $statusItem.Text = 'Running'
            $tray.ShowBalloonTip(2500, 'Casein is ready', 'Double-click the tray icon to open it.', [Windows.Forms.ToolTipIcon]::Info)
        } else {
            $tray.Icon = $errorIcon
            $tray.Text = 'Casein - Start failed'
            $statusItem.Text = 'Start failed'
        }
        [Windows.Forms.Application]::Run()
    } finally {
        $timer.Dispose()
        $tray.Dispose()
        $menu.Dispose()
        $runningIcon.Dispose()
        $stoppedIcon.Dispose()
        $errorIcon.Dispose()
        foreach ($bitmap in $script:IconBitmaps) { $bitmap.Dispose() }
        $script:InstanceMutex.ReleaseMutex()
        $script:InstanceMutex.Dispose()
    }
}

$script:Paths = Get-DevIDEPaths $ReleaseRoot
$script:RuntimeJob = $null
New-Item -ItemType Directory -Force -Path $script:Paths.DataRoot | Out-Null

if (-not $LibraryOnly) {
    try {
        Start-DevIDETray
    } catch {
        Write-DevIDELog "Fatal tray host error: $($_.Exception.ToString())"
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show(
            "Casein could not start.`r`n`r`n$($_.Exception.Message)`r`n`r`nLog: $($script:Paths.Log)",
            'Casein',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 1
    }
}
