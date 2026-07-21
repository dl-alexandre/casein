defmodule DevIDE.Desktop.WindowsTrayHostTest do
  use ExUnit.Case, async: true

  @tray_script Path.expand("../../../windows/DevIDE.Tray.ps1", __DIR__)
  @package_script Path.expand("../../../scripts/package-windows-desktop.ps1", __DIR__)
  @installer Path.expand("../../../windows/Install-DevIDE.ps1", __DIR__)
  @launcher Path.expand("../../../windows/DevIDE.Launcher.ps1", __DIR__)
  @uninstaller Path.expand("../../../windows/Uninstall-DevIDE.ps1", __DIR__)

  test "tray host supervises the loopback desktop release" do
    script = File.read!(@tray_script)

    assert script =~ "System.Windows.Forms"
    assert script =~ "Windows.Forms.NotifyIcon"
    assert script =~ "http://127.0.0.1:$Port/healthz"
    assert script =~ "function New-DevIDELaunchClaim"
    assert script =~ "[Security.Cryptography.HMACSHA256]"
    assert script =~ "desktop_nonce={0}&desktop_timestamp={1}&desktop_proof={2}"
    refute script =~ "?desktop_token="
    assert script =~ "[Security.Cryptography.ProtectedData]::Protect"
    assert script =~ "[Security.Cryptography.ProtectedData]::Unprotect"
    assert script =~ "dpapi:"
    assert script =~ "'DEV_IDE_PROFILE' = 'desktop'"
    assert script =~ "'DEV_IDE_REPO_ADAPTER' = 'sqlite'"
    assert script =~ "'DEVIDE_RELEASE_ROOT' = $script:Paths.ReleaseRoot"
    assert script =~ "'DEV_IDE_API_TOKEN' = $apiToken"
    assert script =~ "'DEV_IDE_DESKTOP_LAUNCH_TOKEN' = $launchToken"
    assert script =~ "'RELEASE_DISTRIBUTION' = 'none'"
    assert script =~ "'RELEASE_TMP' = $script:Paths.RuntimeTemp"
    assert script =~ "$runtime = Invoke-DevIDERelease -Arguments @('start') -Port $Port"
    assert script =~ "JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE"
    assert script =~ "AssignProcessToJobObject"
    assert script =~ "function Clear-DevIDEStaleRuntimeState"
    assert script =~ "Remove-Item -LiteralPath $script:Paths.RuntimeStatus"
    assert script =~ "Attempting automatic runtime recovery"
    refute script =~ "Invoke-DevIDERelease -Arguments @('start') -Port $Port -Wait"
    assert script =~ "taskkill.exe /PID $runtimePid /T /F"
    assert script =~ "Local\\DevIDE.Desktop.Tray"
    assert script =~ "function Open-DevIDECockpit"
    assert script =~ "Opened the already-running DevIDE cockpit from a second launch"
    assert script =~ "$maxBytes = 2MB"
  end

  test "tray menu exposes the required lifecycle controls" do
    script = File.read!(@tray_script)

    for label <- [
          "Open DevIDE",
          "Restart",
          "Open logs",
          "Launch at Windows sign-in",
          "Quit DevIDE"
        ] do
      assert script =~ label
    end
  end

  test "packager builds the Windows SQLite release and copies the host" do
    script = File.read!(@package_script)

    assert script =~ "$env:DEV_IDE_NATIVE_WINDOWS = 'true'"
    assert script =~ "$env:DEV_IDE_REPO_ADAPTER = 'sqlite'"
    assert script =~ "Asset dependencies are missing"
    assert script =~ "@('compile', '--force')"
    assert script =~ "@('release', 'dev_ide', '--overwrite')"
    assert script =~ "DEVIDE_GIT_REVISION = $sourceRevision"
    assert script =~ "Read-DesktopReleaseMetadata"
    assert script =~ "Refusing to package a dirty source tree"
    assert script =~ "New-DesktopArchive"
    assert script =~ "tar.exe"
    assert script =~ "Get-FileHash -Algorithm SHA256"
    assert script =~ "windows\\DevIDE.Tray.ps1"
    assert script =~ "windows\\Install-DevIDE.ps1"
    assert script =~ "pwa-icon-192.png"
    assert script =~ "windows\\DevIDE.png"
  end

  test "tray uses the DevIDE code mark with status badges" do
    script = File.read!(@tray_script)

    assert script =~ "Join-Path $PSScriptRoot 'DevIDE.png'"
    assert script =~ "$graphics.DrawImage($source"
    assert script =~ "$graphics.FillEllipse($statusBrush"
    refute script =~ "$graphics.DrawString('D'"
  end

  test "per-user installer stages an update with a user-data backup" do
    installer = File.read!(@installer)
    launcher = File.read!(@launcher)
    uninstaller = File.read!(@uninstaller)

    assert installer =~ "Programs\\DevIDE"
    assert installer =~ "before-update-"
    assert installer =~ "previous_data_backup"
    refute installer =~ "@('devide.sqlite3', 'desktop-host.json', 'secret-key-base.txt'"

    assert installer =~
             "Move-Item -LiteralPath $temporaryCurrent -Destination $currentPath -Force"

    assert launcher =~ "current.json"
    assert launcher =~ "DevIDE.Tray.ps1"
    assert uninstaller =~ "RemoveUserData"
  end
end
