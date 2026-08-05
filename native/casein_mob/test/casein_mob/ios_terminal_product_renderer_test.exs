defmodule CaseinMob.IOSTerminalProductRendererTest do
  use ExUnit.Case, async: true

  @ios_dir Path.expand("../../ios", __DIR__)
  @parser Path.join(@ios_dir, "CaseinTerminalANSIParser.swift")
  @parser_regression Path.join(@ios_dir, "tests/CaseinTerminalANSIParserRegression.swift")
  @swift Path.join(@ios_dir, "CaseinTerminalRenderer.swift")
  @probe Path.join(@ios_dir, "CaseinTerminalRendererProbe.swift")
  @config Path.expand("../../mob.exs", __DIR__)

  test "production renderer is an iOS 17-compatible Casein-owned pixel surface" do
    swift = File.read!(@swift)
    parser = File.read!(@parser)

    assert swift =~ "struct CaseinCanvasTerminalRenderer"
    assert swift =~ "struct CaseinTerminalCanvasSurface"
    assert swift =~ ".accessibilityHidden(true)"
    assert parser =~ "maximumFrameBytes = 65_536"
    assert parser =~ "bytes.prefix(maximumFrameBytes)"
    assert parser =~ "consumeControlString"
    assert parser =~ "caseinIsTerminalControl"

    for forbidden <- [
          "import Citadel",
          "import GhosttyKit",
          "import Network",
          "SSHClient",
          "URLSession",
          "Process("
        ] do
      refute swift =~ forbidden
    end
  end

  test "host rejects stale identity and reveals only an active fresh baseline" do
    swift = File.read!(@swift)

    assert swift =~ "struct CaseinTerminalRenderGeneration: Equatable"
    assert swift =~ "guard self.generation == generation else { return false }"
    assert swift =~ "guard generationReadyForBaseline else { return false }"
    assert swift =~ "UIApplication.shared.applicationState == .active"
    assert swift =~ "generationReadyForBaseline = false"
    assert swift =~ "showPrivacyCover()"
    assert swift =~ "hidePrivacyCover()"
  end

  test "UIKit privacy cover stays synchronous and foreground requires rebaseline" do
    swift = File.read!(@swift)

    assert swift =~ "UIApplication.willResignActiveNotification"
    assert swift =~ "UIApplication.didBecomeActiveNotification"
    assert swift =~ "view.bringSubviewToFront(privacyCover)"
    assert swift =~ "Terminal waiting for a fresh baseline"
    assert swift =~ "The transport must begin a new connection generation"

    did_become_active =
      swift
      |> String.split("@objc private func applicationDidBecomeActive()", parts: 2)
      |> List.last()
      |> String.split("private func showPrivacyCover()", parts: 2)
      |> List.first()

    assert did_become_active =~ "showPrivacyCover()"
    refute did_become_active =~ "hidePrivacyCover()"
  end

  test "generation replacement synchronously clears old pixels" do
    swift = File.read!(@swift)

    begin_body =
      swift
      |> String.split("func begin(_ generation: CaseinTerminalRenderGeneration)", parts: 2)
      |> List.last()
      |> String.split("@discardableResult", parts: 2)
      |> List.first()

    assert begin_body =~ "baselineAccepted = false"
    assert begin_body =~ "frame = .empty"
    assert begin_body =~ "surfaceGeneration += 1"
  end

  test "synthetic probe consumes production renderer but remains launch flagged" do
    probe = File.read!(@probe)
    config = File.read!(@config)

    assert probe =~ "CaseinCanvasTerminalRenderer()"
    assert probe =~ "CaseinTerminalCanvasSurface("
    assert probe =~ "--casein-terminal-probe"
    assert probe =~ "CaseinTerminalProbeFixture"
    refute probe =~ "struct CaseinCanvasProbeRenderer"
    assert config =~ "\"ios/CaseinTerminalANSIParser.swift\""
    assert config =~ "\"ios/CaseinTerminalRenderer.swift\""
    assert config =~ "\"ios/CaseinTerminalRendererProbe.swift\""
  end

  test "bounded parser regressions execute under the host Swift toolchain" do
    if xcrun = System.find_executable("xcrun") do
      output = Path.join(System.tmp_dir!(), "casein-terminal-parser-#{System.unique_integer([:positive])}")

      try do
        assert {_, 0} =
                 System.cmd(xcrun, [
                   "swiftc",
                   @parser,
                   @parser_regression,
                   "-o",
                   output
                 ])

        assert {"", 0} = System.cmd(output, [])
      after
        File.rm(output)
      end
    else
      regression = File.read!(@parser_regression)
      assert regression =~ "\\u{001B}]52"
      assert regression =~ "unterminated"
      assert regression =~ "\\u{007F}\\u{0085}"
      assert regression =~ "Data([0x9D])"
    end
  end
end
