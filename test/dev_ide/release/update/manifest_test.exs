defmodule DevIDE.Release.Update.ManifestTest do
  use ExUnit.Case, async: true

  alias DevIDE.Release.Metadata
  alias DevIDE.Release.Update.Manifest

  @manifest_json """
  {
    "manifest_version": 1,
    "channel": "canary",
    "generated_at": "2026-07-02T12:05:00Z",
    "signature": null,
    "artifacts": [
      {
        "app": "devide",
        "version": "0.1.0",
        "revision": "67f393adeadbeef",
        "profile": "lan",
        "repo_adapter": "sqlite",
        "target": "linux-x86_64",
        "url": "https://example.com/devide.tar.gz",
        "sha256": "abc",
        "size": 123,
        "min_installer_metadata_version": 1,
        "changelog_url": "https://example.com/compare"
      }
    ]
  }
  """

  @metadata %{
    metadata_version: 1,
    app: "devide",
    version: "0.1.0",
    revision: "504670cdeadbeef",
    profile: "lan",
    repo_adapter: "sqlite",
    target: "linux-x86_64",
    channel: "canary",
    update_manifest_url: "https://example.com/devide-canary.json",
    built_at: "2026-07-02T12:00:00Z"
  }

  test "decode parses v1 manifest" do
    assert {:ok, manifest} = Manifest.decode(@manifest_json)
    assert manifest.channel == "canary"
    assert length(manifest.artifacts) == 1
  end

  test "fetch decodes application/json responses as raw manifest JSON" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/devide-canary.json", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, @manifest_json)
    end)

    assert {:ok, manifest} =
             Manifest.fetch("http://127.0.0.1:#{bypass.port}/devide-canary.json")

    assert manifest.channel == "canary"
    assert length(manifest.artifacts) == 1
  end

  test "select_artifact matches profile and target" do
    {:ok, manifest} = Manifest.decode(@manifest_json)
    assert {:ok, artifact} = Manifest.select_artifact(manifest, @metadata)
    assert artifact.revision == "67f393adeadbeef"
  end

  test "select_artifact rejects incompatible installer metadata version" do
    json =
      @manifest_json
      |> Jason.decode!()
      |> update_in(["artifacts", Access.at(0), "min_installer_metadata_version"], fn _ -> 99 end)
      |> Jason.encode!()

    {:ok, manifest} = Manifest.decode(json)
    assert Metadata.supported_metadata_version() == 1

    assert {:error, {:incompatible_installer, %{required: 99, supported: 1}}} =
             Manifest.select_artifact(manifest, @metadata)
  end
end
