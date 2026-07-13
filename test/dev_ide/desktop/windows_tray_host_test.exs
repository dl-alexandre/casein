defmodule DevIDE.Desktop.WindowsTrayHostTest do
  use ExUnit.Case, async: true

  @tray_script Path.expand("../../../windows/DevIDE.Tray.ps1", __DIR__)
  @package_script Path.expand("../../../scripts/package-windows-desktop.ps1", __DIR__)

  test "tray host supervises the loopback desktop release" do
    script = File.read!(@tray_script)

    assert script =~ "System.Windows.Forms"
    assert script =~ "Windows.Forms.NotifyIcon"
    assert script =~ "http://127.0.0.1:$Port/healthz"
    assert script =~ "http://127.0.0.1:$script:Port/"
    assert script =~ "'DEV_IDE_PROFILE' = 'desktop'"
    assert script =~ "'DEV_IDE_REPO_ADAPTER' = 'sqlite'"
    assert script =~ "'DEV_IDE_API_TOKEN' = $apiToken"
    assert script =~ "'RELEASE_NODE' = 'dev_ide_desktop'"
    assert script =~ "Invoke-DevIDERelease -Arguments @('stop')"
    assert script =~ "Local\\DevIDE.Desktop.Tray"
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
    assert script =~ "windows\\DevIDE.Tray.ps1"
  end
end
