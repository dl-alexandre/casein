defmodule CaseinMob.IOSRuntimeOverlayTest do
  use ExUnit.Case, async: true

  @ios_dir Path.expand("../../ios", __DIR__)
  @app_delegate Path.join(@ios_dir, "AppDelegate.m")
  @build_device Path.join(@ios_dir, "build_device.zig")
  @guard Path.join(@ios_dir, "CaseinRuntimeOverlay.m")
  @native_test Path.join(@ios_dir, "tests/CaseinRuntimeOverlayTests.m")

  test "device build compiles the guard and AppDelegate enables it" do
    build = File.read!(@build_device)

    assert build =~ ~s(.name = "CaseinRuntimeOverlay")
    assert build =~ ~s(CaseinRuntimeOverlay.m)
    assert build =~ ~s(-DCASEIN_RUNTIME_OVERLAY_GUARD)
  end

  test "runtime verification is fail-closed before the BEAM thread starts" do
    delegate = File.read!(@app_delegate)

    prepare = byte_offset!(delegate, "CaseinRuntimeOverlayPrepare(appModule)")
    blocked = byte_offset!(delegate, "runtimeState == CaseinRuntimeOverlayStateBlocked")

    blocked_return =
      byte_offset!(delegate, ~s(mob_set_startup_error("Signed runtime verification failed))

    create = byte_offset!(delegate, "pthread_create(&t, NULL, beam_thread")

    assert prepare < blocked
    assert blocked < blocked_return
    assert blocked_return < create
    assert delegate =~ "return YES;"
    assert delegate =~ "if (pthread_create(&t, NULL, beam_thread"
  end

  test "guard has bounded validation and preserves rejected overlays by atomic rename" do
    guard = File.read!(@guard)

    for boundary <- [
          "kCaseinManifestMaxBytes",
          "kCaseinOverlayFileMaxBytes",
          "kCaseinOverlayTotalMaxBytes",
          "kCaseinOverlayMaxEntries",
          "kCaseinOverlayMaxPathBytes",
          "kCaseinOverlayMaxDepth"
        ] do
      assert guard =~ boundary
    end

    assert guard =~ ~S|((NSDictionary *)root)[@"files2"]|
    assert guard =~ ~S|entry[@"hash2"]|
    assert guard =~ ~S|entry[@"symlink"]|
    assert guard =~ "CC_SHA256_DIGEST_LENGTH"
    assert guard =~ "O_NOFOLLOW"
    assert guard =~ "S_ISLNK"
    assert guard =~ "rename(overlayPath.fileSystemRepresentation"
    refute guard =~ "removeItemAtPath"
    refute guard =~ "unlink("

    for state <- [
          "signed_bundle",
          "verified_overlay",
          "signed_bundle_after_quarantine",
          "blocked"
        ] do
      assert guard =~ ~s(return "#{state}";)
    end
  end

  if :os.type() == {:unix, :darwin} do
    test "native adversarial overlay harness" do
      executable =
        Path.join(
          System.tmp_dir!(),
          "casein-runtime-overlay-test-#{System.unique_integer([:positive])}"
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
            "-fblocks",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Wno-deprecated-declarations",
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
      assert test_output =~ "CaseinRuntimeOverlayTests:"
      assert test_output =~ "assertions passed"
    end
  else
    @tag skip: "native Objective-C harness requires the macOS SDK"
    test "native adversarial overlay harness", do: :ok
  end

  defp byte_offset!(string, pattern) do
    case :binary.match(string, pattern) do
      {offset, _length} -> offset
      :nomatch -> flunk("missing expected source fragment: #{inspect(pattern)}")
    end
  end
end
