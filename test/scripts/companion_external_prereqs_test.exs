defmodule Scripts.CompanionExternalPrereqsTest do
  @moduledoc """
  Linux-safe lock for issue #416 companion **external prereq** checklist.

  Dry-run greens on fixtures + in-repo contract. Enforce mode exits non-zero
  with structured NEED codes when real material markers are absent.
  Does not codesign, notarize, or install on a device.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/verify-companion-external-prereqs.sh", __DIR__)
  @runbook Path.expand("../../docs/mobile/companion_signing_distribution.md", __DIR__)

  @need_codes ~w(
    APPLE_AGREEMENT
    IOS_DEV_PROFILE
    IOS_PHYSICAL_INSTALL
    ANDROID_STORAGE_INSTALL
    PLAY_PUBLIC_NAME
    ASC_PUBLIC_NAME
    NOTARYTOOL_KEYCHAIN
    APNS_FCM_DELIVERY
    CROSS_ORIGIN_PAIR
  )

  test "external prereq verifier has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "dry-run greens on fixtures and lists NEED codes without secrets" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "casein-companion-external-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(tmp) end)

    {output, status} =
      System.cmd("bash", [@script, "--dry-run", "--json", tmp], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "mode=dry-run"

    assert output =~
             "fixture development=native/casein_mob/test/fixtures/ios_development_profile.plist"

    assert output =~ "NEED APPLE_AGREEMENT"
    assert output =~ "NEED IOS_DEV_PROFILE"
    assert output =~ "NEED IOS_PHYSICAL_INSTALL"
    assert output =~ "NEED CROSS_ORIGIN_PAIR"
    refute output =~ "BEGIN CERTIFICATE"
    refute output =~ "BEGIN PRIVATE KEY"
    refute output =~ "-----BEGIN"

    evidence = tmp |> File.read!() |> Jason.decode!()
    assert evidence["schema"] == 1
    assert evidence["kind"] == "companion_external_prereqs"
    assert evidence["issue"] == 416
    assert evidence["mode"] == "dry-run"
    assert evidence["passed"] == true
    assert evidence["checks"] >= 10
    assert evidence["need_codes"] == @need_codes
    assert evidence["satisfied_codes"] == []
    assert evidence["claims"]["physical_device_install"] == false
    assert evidence["claims"]["real_signing_material"] == false
    assert evidence["claims"]["fixtures_obviously_fake"] == true

    assert evidence["fixtures"]["development"] ==
             "native/casein_mob/test/fixtures/ios_development_profile.plist"
  end

  test "enforce mode exits non-zero with NEED codes when material markers absent" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "casein-companion-external-enforce-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(tmp) end)

    # Scrub companion markers so a polluted agent env cannot false-green.
    scrub =
      System.get_env()
      |> Enum.reject(fn {k, _} -> String.starts_with?(k, "CASEIN_COMPANION_") end)
      |> Map.new()

    {output, status} =
      System.cmd("bash", [@script, "--json", tmp], env: scrub, stderr_to_stdout: true)

    assert status != 0, output
    assert output =~ "mode=enforce"
    assert output =~ "NEED APPLE_AGREEMENT"
    assert output =~ "NEED IOS_DEV_PROFILE"
    assert output =~ "unresolved"

    evidence = tmp |> File.read!() |> Jason.decode!()
    assert evidence["mode"] == "enforce"
    assert evidence["passed"] == false
    assert evidence["need_codes"] == @need_codes
    assert "APPLE_AGREEMENT" in evidence["need_codes"]
    assert "IOS_DEV_PROFILE" in evidence["need_codes"]
    assert evidence["claims"]["physical_device_install"] == false
  end

  test "enforce mode accepts presence-only markers without printing secret values" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "casein-companion-external-markers-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(tmp) end)

    base =
      System.get_env()
      |> Enum.reject(fn {k, _} -> String.starts_with?(k, "CASEIN_COMPANION_") end)
      |> Map.new()

    # Obviously fake marker values — never real certs/profiles/tokens.
    markers = %{
      "CASEIN_COMPANION_APPLE_AGREEMENT_OK" => "1",
      "CASEIN_COMPANION_IOS_DEV_PROFILE_PATH" => "/tmp/FAKE-not-a-real-profile.mobileprovision",
      "CASEIN_COMPANION_IOS_PHYSICAL_OK" => "1",
      "CASEIN_COMPANION_ANDROID_INSTALL_OK" => "1",
      "CASEIN_COMPANION_PLAY_NAME_OK" => "1",
      "CASEIN_COMPANION_ASC_NAME_OK" => "1",
      "CASEIN_COMPANION_NOTARY_PROFILE" => "FAKE-local-keychain-profile-name",
      "CASEIN_COMPANION_PUSH_OK" => "1",
      "CASEIN_COMPANION_CROSS_ORIGIN_OK" => "1"
    }

    {output, status} =
      System.cmd("bash", [@script, "--json", tmp],
        env: Map.merge(base, markers),
        stderr_to_stdout: true
      )

    assert status == 0, output
    refute output =~ "BEGIN CERTIFICATE"
    # Path marker must not dump as a claimed real profile install.
    refute output =~ "real provisioning profile installed"

    evidence = tmp |> File.read!() |> Jason.decode!()
    assert evidence["passed"] == true
    assert evidence["need_codes"] == []
    assert Enum.sort(evidence["satisfied_codes"]) == Enum.sort(@need_codes)
    # Honesty: markers do not upgrade physical claims.
    assert evidence["claims"]["physical_device_install"] == false
    assert evidence["claims"]["real_signing_material"] == false
  end

  test "runbook points operators at external prereq script" do
    body = File.read!(@runbook)
    assert body =~ "verify-companion-external-prereqs.sh"
    assert body =~ "--dry-run"
    assert body =~ "NEED"
  end
end
