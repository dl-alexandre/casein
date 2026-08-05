defmodule CaseinMob.IOSTerminalRendererProbeTest do
  use ExUnit.Case, async: true

  @ios_dir Path.expand("../../ios", __DIR__)
  @swift Path.join(@ios_dir, "CaseinTerminalRendererProbe.swift")
  @delegate Path.join(@ios_dir, "AppDelegate.m")
  @mob_config Path.expand("../../mob.exs", __DIR__)
  @ui_test Path.join(@ios_dir, "CaseinMobSoakUITests/CaseinTerminalRendererProbeUITests.swift")
  @xcode_project Path.join(@ios_dir, "Provision.xcodeproj/project.pbxproj")

  test "probe is an explicit synthetic-only launch surface" do
    swift = File.read!(@swift)
    delegate = File.read!(@delegate)

    assert swift =~ "--casein-terminal-probe"
    assert swift =~ "CaseinTerminalProbeFixture"
    assert swift =~ "Synthetic fixture · no session · read only"
    assert delegate =~ "[CaseinTerminalProbeFactory isEnabled]"

    for forbidden <- [
          "import Citadel",
          "SSHClient",
          "SFTPClient",
          "Process(",
          "URLSession",
          "Network.framework"
        ] do
      refute swift =~ forbidden
    end
  end

  test "Mob native view seam is registered without product navigation" do
    swift = File.read!(@swift)
    delegate = File.read!(@delegate)
    config = File.read!(@mob_config)

    assert swift =~
             "MobNativeViewRegistry.shared.register(\"CaseinMob_IosTerminalProbeComponent\")"

    assert swift =~ "@_cdecl(\"casein_register_terminal_probe\")"
    assert delegate =~ "if ([CaseinTerminalProbeFactory isEnabled])"
    assert delegate =~ "casein_register_terminal_probe();"
    assert swift =~ "if CaseinTerminalProbeFactory.isEnabled()"
    assert config =~ "project_swift_sources: [\"ios/CaseinTerminalRendererProbe.swift\"]"
  end

  test "fixture pixels are excluded from accessibility and inactive transitions are masked" do
    swift = File.read!(@swift)

    assert swift =~ ".accessibilityHidden(true)"
    assert swift =~ "if !applicationIsActive"
    assert swift =~ "UIApplication.didBecomeActiveNotification"
    assert swift =~ "UIApplication.willResignActiveNotification"
    assert swift =~ "Terminal hidden while inactive"
    assert swift =~ "CaseinTerminalProbeHostingController"
    assert swift =~ "privacyCover.isHidden = false"
    refute swift =~ "accessibilityLabel(\"CASEIN SYNTHETIC TERMINAL\")"
    refute swift =~ "accessibilityValue(\"CASEIN SYNTHETIC TERMINAL\")"
  end

  test "renderer façade and generation lifecycle remain Casein-owned" do
    swift = File.read!(@swift)

    assert swift =~ "protocol CaseinTerminalRendererFacade"
    assert swift =~ "struct CaseinCanvasProbeRenderer"
    assert swift =~ "generation += 1"
    assert swift =~ "presentedGenerations.insert(generation).inserted"
    assert swift =~ "surface mount milliseconds"
    assert swift =~ "--casein-terminal-probe-auto-cycles"
    assert swift =~ "completedCycles < 10"
  end

  test "component publishes bounded non-content metadata" do
    assert %{renderer: "casein_canvas", fixture: "synthetic_only", read_only: true} =
             CaseinMob.IosTerminalProbeComponent.render(%{})
  end

  test "signed probe test stays synthetic and is included in the dedicated UI runner" do
    ui_test = File.read!(@ui_test)
    project = File.read!(@xcode_project)

    assert ui_test =~ "Launch the flagged signed app first"
    assert ui_test =~ "cycles 10"
    assert ui_test =~ "XCUIDevice.shared.press(.home)"
    assert ui_test =~ "allElementsBoundByAccessibilityElement"
    assert ui_test =~ "testUnflaggedLaunchDoesNotExposeProbeRootOrControl"
    assert project =~ "DD000001 /* CaseinTerminalRendererProbeUITests.swift in Sources */"
  end
end
