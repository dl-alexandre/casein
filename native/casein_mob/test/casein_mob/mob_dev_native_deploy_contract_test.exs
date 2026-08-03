defmodule CaseinMob.MobDevNativeDeployContractTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Deploy
  alias MobDev.NativeBuild

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
end
