defmodule DevIDE.Desktop.WindowsTrayHostTest do
  use ExUnit.Case, async: true

  @tray_script Path.expand("../../../windows/DevIDE.Tray.ps1", __DIR__)
  @package_script Path.expand("../../../scripts/package-windows-desktop.ps1", __DIR__)
  @preview_prepare Path.expand(
                     "../../../scripts/prepare-windows-preview-runtime.ps1",
                     __DIR__
                   )
  @installer Path.expand("../../../windows/Install-DevIDE.ps1", __DIR__)
  @launcher Path.expand("../../../windows/DevIDE.Launcher.ps1", __DIR__)
  @uninstaller Path.expand("../../../windows/Uninstall-DevIDE.ps1", __DIR__)
  @repair Path.expand("../../../windows/Repair-DevIDE.ps1", __DIR__)
  @support Path.expand("../../../windows/New-DevIDESupportBundle.ps1", __DIR__)

  test "tray host supervises the loopback desktop release" do
    script = File.read!(@tray_script)

    assert script =~ "System.Windows.Forms"
    assert script =~ "Add-Type -AssemblyName System.Security"
    assert script =~ "Windows.Forms.NotifyIcon"
    assert script =~ "http://127.0.0.1:$Port/healthz"
    assert script =~ "function New-DevIDELaunchClaim"
    assert script =~ "[Security.Cryptography.HMACSHA256]"
    assert script =~ "desktop_nonce={0}&desktop_timestamp={1}&desktop_proof={2}"
    refute script =~ "?desktop_token="
    assert script =~ "[System.Security.Cryptography.ProtectedData]::Protect"
    assert script =~ "[System.Security.Cryptography.ProtectedData]::Unprotect"
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
          "Repair installation",
          "Open logs",
          "Create support bundle",
          "Launch at Windows sign-in",
          "Quit DevIDE"
        ] do
      assert script =~ label
    end
  end

  test "repair validates the installed release and reruns migrations" do
    script = File.read!(@repair)

    assert script =~ "StartsWith($releasesRoot"
    assert script =~ "bin\\dev_ide.bat"
    assert script =~ "& $release migrate"
    assert script =~ "Get-Process -Id $runtimePid"
  end

  test "support bundle includes diagnostics but excludes local credentials and data" do
    script = File.read!(@support)

    assert script =~ "desktop-host.log"
    assert script =~ "runtime.json"
    assert script =~ "system.json"
    refute script =~ "Copy-Item -LiteralPath (Join-Path $DataRoot 'api-token.txt')"
    refute script =~ "Copy-Item -LiteralPath (Join-Path $DataRoot 'secret-key-base.txt')"
    refute script =~ "Copy-Item -LiteralPath (Join-Path $DataRoot 'devide.sqlite3')"
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
    assert script =~ "Copy-DesktopTree"
    assert script =~ "robocopy.exe"
    assert script =~ "tar.exe"
    assert script =~ "Get-FileHash -Algorithm SHA256"
    assert script =~ "windows\\DevIDE.Tray.ps1"
    assert script =~ "windows\\Install-DevIDE.ps1"
    assert script =~ "pwa-icon-192.png"
    assert script =~ "windows\\DevIDE.png"
  end

  test "Windows package requires a self-contained Playwright runtime" do
    package = File.read!(@package_script)
    prepare = File.read!(@preview_prepare)

    assert package =~ "Assert-WindowsPreviewRuntime"
    assert package =~ "runtime\\node.exe"
    assert package =~ "playwright-browsers"
    assert prepare =~ "PLAYWRIGHT_BROWSERS_PATH"
    assert prepare =~ "install chromium"
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
    assert installer =~ "Get-Process -Id $runtimePid -ErrorAction SilentlyContinue"
    assert uninstaller =~ "Get-Process -Id $runtimePid -ErrorAction SilentlyContinue"
    assert uninstaller =~ "RemoveUserData"
  end
end
