defmodule DevIDE.Release.Update.InstallPlanTest do
  use ExUnit.Case, async: true

  alias DevIDE.Release.Metadata
  alias DevIDE.Release.Update.InstallPlan
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
        "min_installer_metadata_version": 1
      }
    ]
  }
  """

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("devide-install-plan-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    metadata =
      Metadata.build_for_assemble(
        revision: "504670cdeadbeef",
        profile: "lan",
        repo_adapter: "sqlite",
        target: "linux-x86_64",
        update_manifest_url: "https://example.com/devide-canary.json"
      )

    :ok = Metadata.write!(tmp, metadata)
    {:ok, manifest} = Manifest.decode(@manifest_json)

    %{tmp: tmp, manifest: manifest, metadata: metadata}
  end

  test "build returns update_available with selected artifact", %{tmp: tmp, manifest: manifest} do
    fetcher = fn "https://example.com/devide-canary.json" -> {:ok, manifest} end

    assert {:ok, :update_available, current, artifact, ^manifest, manifest_url} =
             InstallPlan.build(tmp, fetch: fetcher)

    assert current.revision == "504670cdeadbeef"
    assert artifact.revision == "67f393adeadbeef"
    assert manifest_url == "https://example.com/devide-canary.json"
  end

  test "build accepts requested revision prefixes", %{tmp: tmp, manifest: manifest} do
    fetcher = fn _url -> {:ok, manifest} end

    assert {:ok, :update_available, _current, artifact, _manifest, _url} =
             InstallPlan.build(tmp, fetch: fetcher, to: "67f393a")

    assert artifact.revision == "67f393adeadbeef"
  end

  test "build rejects unavailable requested revisions", %{tmp: tmp, manifest: manifest} do
    fetcher = fn _url -> {:ok, manifest} end

    assert {:error, {:requested_revision_unavailable, info}} =
             InstallPlan.build(tmp, fetch: fetcher, to: "deadbee")

    assert info.requested == "deadbee"
    assert info.available == "67f393adeadbeef"
  end

  test "build reports current when manifest revision matches installed release", %{
    tmp: tmp,
    metadata: metadata
  } do
    manifest =
      @manifest_json
      |> Jason.decode!()
      |> update_in(["artifacts", Access.at(0), "revision"], fn _ -> metadata.revision end)
      |> Jason.encode!()
      |> Manifest.decode()
      |> elem(1)

    fetcher = fn _url -> {:ok, manifest} end

    assert {:ok, :current, _current, artifact, _manifest, _url} =
             InstallPlan.build(tmp, fetch: fetcher)

    assert artifact.revision == metadata.revision
  end
end
