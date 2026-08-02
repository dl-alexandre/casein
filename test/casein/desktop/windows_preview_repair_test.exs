defmodule Casein.Desktop.WindowsPreviewRepairTest do
  use ExUnit.Case, async: true

  @repair Path.expand("../../../windows/Repair-Casein.ps1", __DIR__)
  @diagnostic Path.expand("../../../priv/scripts/preview_runtime_diagnostic.mjs", __DIR__)
  @helper Path.expand("../../../priv/scripts/preview_playwright.mjs", __DIR__)

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
end
