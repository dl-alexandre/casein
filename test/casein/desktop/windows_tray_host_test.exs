defmodule Casein.Desktop.WindowsTrayHostTest do
  use ExUnit.Case, async: true

  @tray_script Path.expand("../../../windows/Casein.Tray.ps1", __DIR__)
  @package_script Path.expand("../../../scripts/package-windows-desktop.ps1", __DIR__)
  @preview_prepare Path.expand(
                     "../../../scripts/prepare-windows-preview-runtime.ps1",
                     __DIR__
                   )
  @installer Path.expand("../../../windows/Install-Casein.ps1", __DIR__)
  @launcher Path.expand("../../../windows/Casein.Launcher.ps1", __DIR__)
  @uninstaller Path.expand("../../../windows/Uninstall-Casein.ps1", __DIR__)
  @repair Path.expand("../../../windows/Repair-Casein.ps1", __DIR__)
  @support Path.expand("../../../windows/New-CaseinSupportBundle.ps1", __DIR__)
  @rollback Path.expand("../../../windows/Rollback-Casein.ps1", __DIR__)
  @trusted_lan Path.expand("../../../windows/Casein.TrustedLan.ps1", __DIR__)

  test "tray host supervises the loopback desktop release" do
    script = File.read!(@tray_script)

    assert script =~ "System.Windows.Forms"
    assert script =~ "Add-Type -AssemblyName System.Security"
    assert script =~ "Windows.Forms.NotifyIcon"
    assert script =~ "http://127.0.0.1:$Port/healthz"
    assert script =~ "function New-CaseinLaunchClaim"
    assert script =~ "[Security.Cryptography.HMACSHA256]"
    assert script =~ "desktop_nonce={0}&desktop_timestamp={1}&desktop_proof={2}"
    refute script =~ "?desktop_token="
    assert script =~ "[System.Security.Cryptography.ProtectedData]::Protect"
    assert script =~ "[System.Security.Cryptography.ProtectedData]::Unprotect"
    assert script =~ "dpapi:"
    assert script =~ "'CASEIN_PROFILE' = 'desktop'"
    assert script =~ "'CASEIN_REPO_ADAPTER' = 'sqlite'"
    assert script =~ "'DEVIDE_RELEASE_ROOT' = $script:Paths.ReleaseRoot"
    assert script =~ "'CASEIN_API_TOKEN' = $apiToken"
    assert script =~ "'CASEIN_DESKTOP_LAUNCH_TOKEN' = $launchToken"
    assert script =~ "'RELEASE_DISTRIBUTION' = 'none'"
    assert script =~ "'RELEASE_NODE' = 'casein_desktop'"
    assert script =~ "'RELEASE_TMP' = $script:Paths.RuntimeTemp"
    assert script =~ "$runtime = Invoke-CaseinRelease -Arguments @('start') -Port $Port"
    assert script =~ "JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE"
    assert script =~ "AssignProcessToJobObject"
    assert script =~ "function Clear-CaseinStaleRuntimeState"
    assert script =~ "Remove-Item -LiteralPath $script:Paths.RuntimeStatus"
    assert script =~ "Attempting automatic runtime recovery"
    refute script =~ "Invoke-CaseinRelease -Arguments @('start') -Port $Port -Wait"
    assert script =~ "taskkill.exe /PID $runtimePid /T /F"
    assert script =~ "Local\\Casein.Desktop.Tray"
    assert script =~ "function Open-CaseinCockpit"
    assert script =~ "Opened the already-running Casein cockpit from a second launch"
    assert script =~ "$maxBytes = 2MB"
  end

  test "tray menu exposes the required lifecycle controls" do
    script = File.read!(@tray_script)

    for label <- [
          "Open Casein",
          "Restart",
          "Repair installation",
          "Roll back last update",
          "Open logs",
          "Create support bundle",
          "Trusted LAN access",
          "Copy Trusted LAN URL",
          "Launch at Windows sign-in",
          "Quit Casein"
        ] do
      assert script =~ label
    end
  end

  test "Trusted LAN selects a private physical interface and scopes its firewall rule" do
    script = File.read!(@trusted_lan)
    tray = File.read!(@tray_script)
    uninstaller = File.read!(@uninstaller)

    assert script =~ "Get-NetIPConfiguration -Detailed"
    assert script =~ "Get-NetIPInterface -AddressFamily IPv4"
    assert script =~ "NetworkCategory -ne 'Private'"
    assert script =~ "vpn|wireguard|tailscale|tunnel|tap|tun|hyper-v|vethernet|wsl"
    assert script =~ "Sort-Object"
    assert script =~ "-Profile Private"
    assert script =~ "-LocalAddress $selected.Address"
    assert script =~ "-LocalPort $ListenPort"
    assert script =~ "-Program $program"
    assert script =~ "-RemoteAddress LocalSubnet"
    assert script =~ "Remove-CaseinTrustedLanFirewallRules"
    assert tray =~ "'CASEIN_DESKTOP_LAN'] = 'true'"
    assert tray =~ "'CASEIN_LAN_INSECURE_HTTP'] = 'true'"
    assert tray =~ "'PHX_IP'] = '0.0.0.0'"
    assert uninstaller =~ "-Action Disable"
  end

  test "rollback swaps only between validated installed release roots" do
    script = File.read!(@rollback)

    assert script =~ "previous_release_root"
    assert script =~ "StartsWith($releasesRoot"
    assert script =~ "releases\\casein.relmeta.json"
    assert script =~ "rollback = $true"
  end

  test "repair validates the installed release and reruns migrations" do
    script = File.read!(@repair)

    assert script =~ "StartsWith($releasesRoot"
    assert script =~ "bin\\casein.bat"
    assert script =~ "& $release migrate"
    assert script =~ "Get-Process -Id $runtimePid"
  end

  test "support bundle includes diagnostics but excludes local credentials and data" do
    script = File.read!(@support)

    assert script =~ "desktop-host.log"
    assert script =~ "runtime.json"
    assert script =~ "trusted-lan.json"
    assert script =~ "system.json"
    refute script =~ "Copy-Item -LiteralPath (Join-Path $DataRoot 'api-token.txt')"
    refute script =~ "Copy-Item -LiteralPath (Join-Path $DataRoot 'secret-key-base.txt')"
    refute script =~ "Copy-Item -LiteralPath (Join-Path $DataRoot 'devide.sqlite3')"
  end

  test "packager builds the Windows SQLite release and copies the host" do
    script = File.read!(@package_script)

    assert script =~ "$env:CASEIN_NATIVE_WINDOWS = 'true'"
    assert script =~ "$env:CASEIN_REPO_ADAPTER = 'sqlite'"
    assert script =~ "Asset dependencies are missing"
    assert script =~ "@('compile', '--force')"
    assert script =~ "'_build\\prod\\rel\\casein'"
    assert script =~ "@('release', 'casein', '--overwrite')"
    assert script =~ "app = 'casein'"
    assert script =~ "DEVIDE_GIT_REVISION = $sourceRevision"
    assert script =~ "Read-DesktopReleaseMetadata"
    assert script =~ "Refusing to package a dirty source tree"
    assert script =~ "New-DesktopArchive"
    assert script =~ "Copy-DesktopTree"
    assert script =~ "robocopy.exe"
    assert script =~ "tar.exe"
    assert script =~ "Get-FileHash -Algorithm SHA256"
    assert script =~ "Write-ReleaseTrustManifest"
    assert script =~ "Set-AuthenticodeSignature"

    assert script =~
             "Where-Object { $_.Extension.ToLowerInvariant() -in @('.exe', '.dll', '.ps1', '.psm1') }"

    assert script =~ "Write-SignedUpdateCatalog"
    assert script =~ "New-FileCatalog"
    assert script =~ "Test-FileCatalog"
    assert script =~ "RequireSigned"
    assert script =~ "windows\\Casein.Tray.ps1"
    assert script =~ "windows\\Install-Casein.ps1"
    assert script =~ "pwa-icon-192.png"
    assert script =~ "windows\\Casein.png"
  end

  test "installer verifies signed release identity and file hashes before mutation" do
    script = File.read!(@installer)

    assert script =~ "Test-ReleaseTrust $packageRoot"
    assert script =~ "Get-AuthenticodeSignature"
    assert script =~ "DEVIDE_REQUIRE_SIGNED_RELEASES"
    assert script =~ "Get-FileHash -Algorithm SHA256"
    assert script =~ "Release integrity check failed"
    assert script =~ "SignedFiles"
    assert script =~ "Packaged executable is not trusted"
    assert script =~ "Copy-ReleaseTree"
    assert script =~ "robocopy.exe"
    assert script =~ "Remove-ReleaseTree"
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

  test "tray uses the Casein code mark with status badges" do
    script = File.read!(@tray_script)

    assert script =~ "Join-Path $PSScriptRoot 'Casein.png'"
    assert script =~ "$graphics.DrawImage($source"
    assert script =~ "$graphics.FillEllipse($statusBrush"
    refute script =~ "$graphics.DrawString('D'"
  end

  test "per-user installer stages an update with a user-data backup" do
    installer = File.read!(@installer)
    launcher = File.read!(@launcher)
    uninstaller = File.read!(@uninstaller)

    assert installer =~ "Programs\\Casein"
    assert installer =~ "before-update-"
    assert installer =~ "previous_data_backup"
    refute installer =~ "@('devide.sqlite3', 'desktop-host.json', 'secret-key-base.txt'"

    assert installer =~
             "Move-Item -LiteralPath $temporaryCurrent -Destination $currentPath -Force"

    assert launcher =~ "current.json"
    assert launcher =~ "Casein.Tray.ps1"
    assert installer =~ "Get-Process -Id $runtimePid -ErrorAction SilentlyContinue"
    assert uninstaller =~ "Get-Process -Id $runtimePid -ErrorAction SilentlyContinue"
    assert uninstaller =~ "RemoveUserData"
  end
end
