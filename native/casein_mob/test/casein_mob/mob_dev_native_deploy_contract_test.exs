defmodule CaseinMob.MobDevNativeDeployContractTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Deploy
  alias MobDev.NativeBuild

  # Issue #409 — pin the upstream mob_dev preserve-data contract Casein depends
  # on. Recoverable install failures must never trigger uninstall/clear, and any
  # per-device failure must surface as an error. These tests exercise the pinned
  # MobDev.NativeBuild API with synthetic runners only; they do not install on a
  # physical device.

  test "explicit Android native deploy fails closed when no toolchain target was built" do
    parent = self()

    deployer = fn opts ->
      send(parent, {:deployer_called, opts})
      {[], [], []}
    end

    # An unavailable Android toolchain contributes no native build result.
    outcome = NativeBuild.build_outcome([])

    assert outcome == %{
             ok?: false,
             android_device_disposition: :not_attempted,
             android_serials: [],
             android_deploy_lock: nil,
             android_payload_plan: nil
           }

    assert_raise Mix.Error, "Native build failed", fn ->
      ExUnit.CaptureIO.capture_io(fn ->
        Deploy.deploy_after_native_build!(
          true,
          outcome,
          [platforms: [:android], device: "explicit-android-target"],
          deployer
        )
      end)
    end

    refute_received {:deployer_called, _opts}
  end

  describe "Android APK update preserve-data contract (#409)" do
    test "classifies recoverable failures without treating them as clean-reinstall triggers" do
      cases = [
        {"Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]", :insufficient_storage},
        {"error: device offline", :offline},
        {"error: device unauthorized", :unauthorized},
        {"error: device not found", :unavailable},
        {"Failure [INSTALL_FAILED_DEXOPT]", :install_rejected}
      ]

      for {output, reason} <- cases do
        assert {:failed, ^reason} = NativeBuild.interpret_adb_update(output, 1)
      end
    end

    test "classifies signature and version incompatibilities as explicit package rejections" do
      assert {:failed, :signature_mismatch} =
               NativeBuild.interpret_adb_update(
                 "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]",
                 1
               )

      assert {:failed, :signature_mismatch} =
               NativeBuild.interpret_adb_update(
                 "Failure [INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES]",
                 1
               )

      assert {:failed, :version_downgrade} =
               NativeBuild.interpret_adb_update(
                 "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]",
                 1
               )
    end

    test "deprecated direct multi-device install refuses before any adb mutation" do
      parent = self()
      apk = "/synthetic/casein-preserve-data.apk"

      runner = fn command, args ->
        send(parent, {:adb_mutation, command, args})
        {"Success\n", 0}
      end

      assert {:error, :authoritative_transaction_required} =
               apply(NativeBuild, :install_android_updates, [
                 apk,
                 ["device-a", "device-b"],
                 runner
               ])

      refute_received {:adb_mutation, _, _}
    end

    test "pinned NativeBuild install path is update-only (install -r, never uninstall)" do
      source =
        Mix.Project.deps_paths()
        |> Map.fetch!(:mob_dev)
        |> Path.join("lib/mob_dev/native_build.ex")
        |> File.read!()

      assert source =~ ~s(["-s", serial, "install", "-r", apk])
      refute source =~ "needs_clean_reinstall?"
      refute source =~ "uninstall"
      assert source =~ "preserving app data"
    end

    test "offline and unauthorized discovery fail closed without install attempts" do
      parent = self()

      offline_runner = fn "adb", ["devices"] ->
        send(parent, :discovery)
        {"List of devices attached\ndev-offline\toffline\n", 0}
      end

      unauthorized_runner = fn "adb", ["devices"] ->
        send(parent, :discovery)
        {"List of devices attached\ndev-auth\tunauthorized\n", 0}
      end

      assert {:error, :offline} =
               NativeBuild.resolve_android_update_targets("dev-offline", offline_runner)

      assert {:error, :unauthorized} =
               NativeBuild.resolve_android_update_targets("dev-auth", unauthorized_runner)

      assert_received :discovery
      assert_received :discovery
    end

    test "deploy task documents update-only Android native installs" do
      source =
        Mix.Project.deps_paths()
        |> Map.fetch!(:mob_dev)
        |> Path.join("lib/mix/tasks/mob.deploy.ex")
        |> File.read!()

      assert source =~ "adb install -r"
      assert source =~ "never uninstalls"
      assert source =~ "preserving app data"
    end
  end
end
