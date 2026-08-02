defmodule CaseinMob.IOSScannerBoundaryProbeTest do
  use ExUnit.Case, async: true

  @ios_dir Path.expand("../../ios", __DIR__)
  @app_delegate Path.join(@ios_dir, "AppDelegate.m")
  @bridge Path.join(@ios_dir, "CaseinScannerBoundaryProbe.m")
  @build Path.join(@ios_dir, "build.zig")
  @build_device Path.join(@ios_dir, "build_device.zig")
  @native_test Path.join(@ios_dir, "tests/CaseinScannerBoundaryProbeTests.m")
  @vector_path Path.expand("../fixtures/compact_pairing_vectors.json", __DIR__)
  @receiver Path.expand("../../lib/casein_mob/scanner_boundary_probe.ex", __DIR__)

  test "simulator and signed-device builds compile and link the probe" do
    for build <- [File.read!(@build), File.read!(@build_device)] do
      assert build =~ ~s(.name = "CaseinScannerBoundaryProbe")
      assert build =~ "CaseinScannerBoundaryProbe.m"
      assert build =~ ~s("Security")
    end
  end

  test "diagnostic URL is consumed before normal pairing and review routing" do
    delegate = File.read!(@app_delegate)

    probe = byte_offset!(delegate, "CaseinScannerBoundaryProbeHandleURL(url)")
    review = byte_offset!(delegate, "MobNotificationJSONFromReviewURL(url)")
    pair = byte_offset!(delegate, "MobNotificationJSONFromPairURL(url)")

    assert probe < review
    assert probe < pair
    assert delegate =~ ~s(#import "CaseinScannerBoundaryProbe.h")
  end

  test "native boundary uses only the public golden vector and exact scanner term shape" do
    bridge = File.read!(@bridge)
    [vector] = Jason.decode!(File.read!(@vector_path))

    [native_vector] =
      Regex.run(
        ~r/kCaseinScannerBoundaryGoldenURI\s*=\s*\n\s*"([^"]+)";/,
        bridge,
        capture: :all_but_first
      )

    assert native_vector == vector["uri"]
    assert bridge =~ ~s|enif_make_atom(env, "casein_scanner_boundary_probe")|
    assert bridge =~ ~s|enif_make_atom(env, "type")|
    assert bridge =~ ~s|enif_make_atom(env, "value")|
    assert bridge =~ ~s|enif_make_atom(env, "qr")|
    assert bridge =~ "enif_make_binary(env, &valueBinary)"
    assert bridge =~ "enif_make_map_from_arrays"
    assert bridge =~ "enif_make_tuple3"
    assert bridge =~ "enif_send(NULL, &receiver, env, message)"
    assert bridge =~ ~s|CFSTR("get-task-allow")|

    for forbidden <- [
          "AVCapture",
          "DeviceLink",
          "NSURLSession",
          "SessionConfig",
          "pair_device",
          "exchange"
        ] do
      refute bridge =~ forbidden
    end
  end

  test "receiver is parser-only and telemetry has a fixed privacy allowlist" do
    receiver = File.read!(@receiver)

    assert receiver =~ "PairingCode.decode(value)"

    for field <- [
          "scan_type",
          "byte_count",
          "compact_prefix",
          "base64url_segment",
          "rejection_stage",
          "rejection_reason"
        ] do
      assert receiver =~ field
    end

    for forbidden <- [
          "DeviceLink",
          "SessionConfig",
          "Req.",
          "Finch",
          "Slipstream",
          "pair_device",
          "exchange"
        ] do
      refute receiver =~ forbidden
    end
  end

  if :os.type() == {:unix, :darwin} do
    test "production bridge compiles for the signed-device SDK" do
      object =
        Path.join(
          System.tmp_dir!(),
          "casein-scanner-boundary-probe-#{System.unique_integer([:positive])}.o"
        )

      on_exit(fn -> File.rm(object) end)

      erts_include =
        Path.join([
          List.to_string(:code.root_dir()),
          "erts-#{:erlang.system_info(:version)}",
          "include"
        ])

      {compile_output, compile_status} =
        System.cmd(
          "xcrun",
          [
            "--sdk",
            "iphoneos",
            "clang",
            "-arch",
            "arm64",
            "-miphoneos-version-min=17.0",
            "-fobjc-arc",
            "-fmodules",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-I#{erts_include}",
            "-c",
            @bridge,
            "-o",
            object
          ],
          stderr_to_stdout: true
        )

      assert compile_status == 0, compile_output
      assert File.stat!(object).size > 0
    end

    test "native exact-URL adversarial harness" do
      executable =
        Path.join(
          System.tmp_dir!(),
          "casein-scanner-boundary-probe-test-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm(executable) end)

      {compile_output, compile_status} =
        System.cmd(
          "xcrun",
          [
            "--sdk",
            "macosx",
            "clang",
            "-fobjc-arc",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-framework",
            "Foundation",
            @native_test,
            "-o",
            executable
          ],
          stderr_to_stdout: true
        )

      assert compile_status == 0, compile_output

      {test_output, test_status} = System.cmd(executable, [], stderr_to_stdout: true)
      assert test_status == 0, test_output
      assert test_output =~ "CaseinScannerBoundaryProbeTests:"
      assert test_output =~ "assertions passed"
    end
  else
    @tag skip: "native Objective-C harness requires the macOS SDK"
    test "native exact-URL adversarial harness", do: :ok
  end

  defp byte_offset!(string, pattern) do
    case :binary.match(string, pattern) do
      {offset, _length} -> offset
      :nomatch -> flunk("missing expected source fragment: #{inspect(pattern)}")
    end
  end
end
