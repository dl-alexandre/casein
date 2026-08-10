defmodule Scripts.CompanionSigningContractTest do
  @moduledoc """
  Linux-safe lock for issue #416 companion signing/distribution **contract**.

  Does not codesign, notarize, or install on a device. Fixtures are synthetic.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/verify-companion-signing-contract.sh", __DIR__)
  @runbook Path.expand("../../docs/mobile/companion_signing_distribution.md", __DIR__)
  @mob Path.expand("../../native/casein_mob", __DIR__)

  test "contract verifier has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "in-repo companion signing contract passes without secrets or devices" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "casein-companion-signing-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(tmp) end)

    {output, status} =
      System.cmd("bash", [@script, "--json", tmp], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "checks passed"
    refute output =~ "BEGIN CERTIFICATE"
    refute output =~ "BEGIN PRIVATE KEY"

    evidence = tmp |> File.read!() |> Jason.decode!()
    assert evidence["schema"] == 1
    assert evidence["kind"] == "companion_signing_contract"
    assert evidence["issue"] == 416
    assert evidence["passed"] == true
    assert evidence["checks"] >= 30

    claims = evidence["claims"]
    assert claims["in_repo_debug_release_split"] == true
    assert claims["public_product_name_casein"] == true
    assert claims["physical_device_install"] == false
    assert claims["gatekeeper_notarization"] == false
    assert claims["play_console_upload"] == false
    assert claims["apns_fcm_delivery"] == false
    assert claims["cross_origin_physical_pairing"] == false
  end

  test "runbook keeps physical reach and operator steps explicit" do
    body = File.read!(@runbook)

    assert body =~ "#416"
    assert body =~ "cannot be completed from this box"
    assert body =~ "aps-environment=development"
    assert body =~ "0xe8008015"
    assert body =~ "INSTALL_FAILED_INSUFFICIENT_STORAGE"
    assert body =~ "notarytool"
    assert body =~ "verify-companion-signing-contract.sh"
    assert body =~ "mutate a Devbox"

    refute body =~ "BEGIN CERTIFICATE"
    refute body =~ "BEGIN PRIVATE KEY"
    refute body =~ "-----BEGIN"
  end

  test "mob gitignore refuses Apple and Play secret droppings" do
    gitignore = File.read!(Path.join(@mob, ".gitignore"))

    for needle <- [
          "android/keystore.properties",
          "android/*.keystore",
          "*.mobileprovision",
          "*.p12",
          "AuthKey_*.p8",
          "google-services.json"
        ] do
      assert gitignore =~ needle
    end
  end

  test "synthetic fixtures stay labeled fake and split push environments" do
    dev = File.read!(Path.join(@mob, "test/fixtures/ios_development_profile.plist"))
    dist = File.read!(Path.join(@mob, "test/fixtures/ios_distribution_profile.plist"))

    assert dev =~ "development"
    assert dist =~ "production"

    assert String.contains?(dist, "Obviously fake") or String.contains?(dist, "FAKE iOS") or
             String.contains?(dist, "Not a real")

    assert String.contains?(dev, "Sanitized contract") or String.contains?(dev, "Obviously fake") or
             String.contains?(dev, "FAKE")

    refute dist =~ "get-task-allow"
    assert dev =~ "get-task-allow"
  end
end
