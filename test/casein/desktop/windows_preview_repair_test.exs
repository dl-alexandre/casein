defmodule Casein.Desktop.WindowsPreviewRepairTest do
  use ExUnit.Case, async: true

  @repair Path.expand("../../../windows/Repair-Casein.ps1", __DIR__)
  @diagnostic Path.expand("../../../priv/scripts/preview_runtime_diagnostic.mjs", __DIR__)
  @helper Path.expand("../../../priv/scripts/preview_playwright.mjs", __DIR__)
  @package_smoke Path.expand("../../../scripts/test-windows-desktop-package.ps1", __DIR__)

  test "repair performs a release-local headless Chromium diagnostic" do
    repair = File.read!(@repair)
    helper = File.read!(@helper)

    assert repair =~ "function Test-CaseinPreviewRuntime"
    assert repair =~ "runtime\\node.exe"
    assert repair =~ "playwright-browsers"
    assert repair =~ ~s/'{"action":"diagnose"}'/
    assert repair =~ "Reinstall Casein from a verified package or roll back"
    assert helper =~ ~s/case "diagnose"/
    assert helper =~ "diagnoseChromium(chromium"
  end

  test "diagnostic classifies missing and unlaunchable Chromium" do
    diagnostic = File.read!(@diagnostic)

    assert diagnostic =~ "chromium_missing"
    assert diagnostic =~ "chromium_launch_failed"
    assert diagnostic =~ "await browser.close().catch"
    assert diagnostic =~ "reinstall Casein from a verified package or roll back"
  end

  test "package smoke walks the packaged preview bridge action path" do
    smoke = File.read!(@package_smoke)
    helper = File.read!(@helper)

    assert smoke =~ "function Invoke-PackagedPreviewBridgeWalk"

    assert smoke =~
             "Invoke-PackagedPreviewBridgeWalk -NodePath $previewNode -HelperPath $previewHelper"

    assert smoke =~ "--daemon"
    assert smoke =~ "action = 'observe_live'"
    assert smoke =~ "action = 'type'"
    assert smoke =~ "action = 'click'"
    assert smoke =~ "action = 'press'"
    assert smoke =~ "action = 'screenshot'"
    assert smoke =~ "action = 'reload'"
    assert smoke =~ "action = 'close'"
    assert smoke =~ "data:image/png;base64,"
    assert smoke =~ "Casein Preview Bridge Fixture"

    assert helper =~ ~s/case "observe_live"/
    assert helper =~ ~s/case "click"/
    assert helper =~ ~s/case "type"/
    assert helper =~ ~s/case "press"/
    assert helper =~ ~s/case "screenshot"/
    assert helper =~ ~s/case "reload"/
    assert helper =~ ~s/case "close"/
    assert helper =~ "process.argv.includes(\"--daemon\")"
  end
end
