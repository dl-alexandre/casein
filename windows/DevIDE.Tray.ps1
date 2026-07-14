[CmdletBinding()]
param(
    [string]$ReleaseRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DevIDEPaths {
    param([string]$Root)

    $dataRoot = if ($env:DEV_IDE_DESKTOP_DATA_DIR) {
        $env:DEV_IDE_DESKTOP_DATA_DIR
    } else {
        Join-Path $env:LOCALAPPDATA 'DevIDE'
    }

    [pscustomobject]@{
        ReleaseRoot = [IO.Path]::GetFullPath($Root)
        ReleaseBat  = Join-Path $Root 'bin\dev_ide.bat'
        DataRoot    = $dataRoot
        Database    = Join-Path $dataRoot 'devide.sqlite3'
        Settings    = Join-Path $dataRoot 'desktop-host.json'
        Log         = Join-Path $dataRoot 'desktop-host.log'
        StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'DevIDE.lnk'
    }
}

function Write-DevIDELog {
    param([string]$Message)

    $line = '{0:o} {1}' -f [DateTime]::UtcNow, $Message
    Add-Content -LiteralPath $script:Paths.Log -Value $line -Encoding UTF8
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
        [IO.File]::WriteAllText($Path, [Convert]::ToBase64String($buffer))
    }

    (Get-Content -Raw -LiteralPath $Path).Trim()
}

function Get-DevIDEEnvironment {
    param([int]$Port)

    $secret = Get-OrCreateDevIDESecret (Join-Path $script:Paths.DataRoot 'secret-key-base.txt') 64
    $apiToken = Get-OrCreateDevIDESecret (Join-Path $script:Paths.DataRoot 'api-token.txt') 48

    @{
        'DEV_IDE_PROFILE' = 'desktop'
        'DEV_IDE_DESKTOP_DATA_DIR' = $script:Paths.DataRoot
        'DEV_IDE_REPO_ADAPTER' = 'sqlite'
        'DATABASE_PATH' = $script:Paths.Database
        'PHX_SERVER' = 'true'
        'PHX_HOST' = 'localhost'
        'PHX_IP' = '127.0.0.1'
        'PORT' = [string]$Port
        'RELEASE_NODE' = 'dev_ide_desktop'
        'SECRET_KEY_BASE' = $secret
        'DEV_IDE_API_TOKEN' = $apiToken
    }
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

    if (Test-DevIDEReady $Port) { return $true }
    Write-DevIDELog "Starting desktop runtime on 127.0.0.1:$Port"
    Invoke-DevIDERelease -Arguments @('eval', 'DevIde.Release.migrate()') -Port $Port -Wait | Out-Null
    # On Windows the release `start` command remains attached to the daemon it
    # launches. Waiting for that command therefore waits until DevIDE stops and
    # then misreports the shutdown exit code as a startup failure.
    Invoke-DevIDERelease -Arguments @('start') -Port $Port | Out-Null
    $ready = Wait-DevIDEReady $Port
    Write-DevIDELog "Runtime ready: $ready"
    $ready
}

function Stop-DevIDERuntime {
    param([int]$Port)

    if (-not (Test-DevIDEReady $Port)) { return }
    Write-DevIDELog 'Stopping desktop runtime'
    try {
        Invoke-DevIDERelease -Arguments @('stop') -Port $Port -Wait | Out-Null
    } catch {
        Write-DevIDELog "Graceful stop failed: $($_.Exception.Message)"
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
        $shortcut.Description = 'Start DevIDE in the Windows notification area'
        $shortcut.Save()
    } else {
        Remove-Item -LiteralPath $script:Paths.StartupLink -Force -ErrorAction SilentlyContinue
    }
}

function New-DevIDEIcon {
    param([Drawing.Color]$Background)

    $bitmap = [Drawing.Bitmap]::new(32, 32)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::Transparent)
    $brush = [Drawing.SolidBrush]::new($Background)
    $font = [Drawing.Font]::new('Segoe UI', 18, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $textBrush = [Drawing.Brushes]::White
    try {
        $graphics.FillEllipse($brush, 1, 1, 30, 30)
        $format = [Drawing.StringFormat]::new()
        $format.Alignment = [Drawing.StringAlignment]::Center
        $format.LineAlignment = [Drawing.StringAlignment]::Center
        $graphics.DrawString('D', $font, $textBrush, [Drawing.RectangleF]::new(0, -1, 32, 32), $format)
        return [Drawing.Icon]::FromHandle($bitmap.GetHicon())
    } finally {
        $font.Dispose()
        $brush.Dispose()
        $graphics.Dispose()
        # Keep the bitmap alive because the icon owns its native handle for the tray lifetime.
        $script:IconBitmaps.Add($bitmap)
    }
}

function Start-DevIDETray {
    $createdNew = $false
    $script:InstanceMutex = New-Object Threading.Mutex($true, 'Local\DevIDE.Desktop.Tray', [ref]$createdNew)
    if (-not $createdNew) {
        $script:InstanceMutex.Dispose()
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $script:IconBitmaps = [Collections.Generic.List[Drawing.Bitmap]]::new()
    $settings = Read-DevIDESettings
    $script:Port = Get-DevIDEPort $settings.port
    $script:LaunchAtSignIn = [bool]$settings.launchAtSignIn
    Save-DevIDESettings $script:Port $script:LaunchAtSignIn

    $runningIcon = New-DevIDEIcon ([Drawing.Color]::FromArgb(37, 99, 235))
    $stoppedIcon = New-DevIDEIcon ([Drawing.Color]::FromArgb(107, 114, 128))
    $errorIcon = New-DevIDEIcon ([Drawing.Color]::FromArgb(220, 38, 38))

    $tray = [Windows.Forms.NotifyIcon]::new()
    $tray.Text = 'DevIDE is starting'
    $tray.Icon = $stoppedIcon
    $tray.Visible = $true

    $menu = [Windows.Forms.ContextMenuStrip]::new()
    $statusItem = $menu.Items.Add('Starting...')
    $statusItem.Enabled = $false
    [void]$menu.Items.Add('-')
    $openItem = $menu.Items.Add('Open DevIDE')
    $restartItem = $menu.Items.Add('Restart')
    $logsItem = $menu.Items.Add('Open logs')
    $startupItem = $menu.Items.Add('Launch at Windows sign-in')
    $startupItem.Checked = $script:LaunchAtSignIn
    [void]$menu.Items.Add('-')
    $quitItem = $menu.Items.Add('Quit DevIDE')
    $tray.ContextMenuStrip = $menu

    $open = {
        if (Test-DevIDEReady $script:Port) {
            Start-Process "http://127.0.0.1:$script:Port/"
        } else {
            $tray.ShowBalloonTip(3000, 'DevIDE', 'DevIDE is not ready yet.', [Windows.Forms.ToolTipIcon]::Info)
        }
    }
    $openItem.Add_Click($open)
    $tray.Add_DoubleClick($open)
    $logsItem.Add_Click({ Start-Process explorer.exe -ArgumentList @($script:Paths.DataRoot) })
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
            $tray.ShowBalloonTip(5000, 'DevIDE failed to start', "Open logs for details.", [Windows.Forms.ToolTipIcon]::Error)
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
            $tray.Text = 'DevIDE - Running'
            $tray.Icon = $runningIcon
            $openItem.Enabled = $true
        } else {
            $statusItem.Text = 'Stopped'
            $tray.Text = 'DevIDE - Stopped'
            $tray.Icon = $errorIcon
            $openItem.Enabled = $false
        }
    })
    $timer.Start()

    try {
        if (Start-DevIDERuntime $script:Port) {
            $tray.Icon = $runningIcon
            $tray.Text = 'DevIDE - Running'
            $statusItem.Text = 'Running'
            $tray.ShowBalloonTip(2500, 'DevIDE is ready', 'Double-click the tray icon to open it.', [Windows.Forms.ToolTipIcon]::Info)
        } else {
            $tray.Icon = $errorIcon
            $tray.Text = 'DevIDE - Start failed'
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
New-Item -ItemType Directory -Force -Path $script:Paths.DataRoot | Out-Null

if (-not $LibraryOnly) {
    try {
        Start-DevIDETray
    } catch {
        Write-DevIDELog "Fatal tray host error: $($_.Exception.ToString())"
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show(
            "DevIDE could not start.`r`n`r`n$($_.Exception.Message)`r`n`r`nLog: $($script:Paths.Log)",
            'DevIDE',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 1
    }
}
