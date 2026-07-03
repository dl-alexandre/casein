defmodule DevIDE.Release.Update.CheckTest do
  use ExUnit.Case, async: false

  alias DevIDE.Release.Metadata
  alias DevIDE.Release.Update.Check

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
    tmp = System.tmp_dir!() |> Path.join("devide-check-#{System.unique_integer([:positive])}")
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
    prev_root = System.get_env("DEVIDE_RELEASE_ROOT")
    System.put_env("DEVIDE_RELEASE_ROOT", tmp)

    on_exit(fn ->
      if prev_root,
        do: System.put_env("DEVIDE_RELEASE_ROOT", prev_root),
        else: System.delete_env("DEVIDE_RELEASE_ROOT")
    end)

    fetcher = fn _url -> {:ok, decode_manifest()} end
    %{fetcher: fetcher, metadata: metadata}
  end

  test "run reports update_available when revision differs", %{fetcher: fetcher} do
    result = Check.run(fetch: fetcher)
    assert result.status == :update_available
    assert result.available.revision == "67f393adeadbeef"
    assert result.current.revision == "504670cdeadbeef"
  end

  test "run reports current when revision matches", %{metadata: metadata} do
    same =
      @manifest_json
      |> Jason.decode!()
      |> update_in(["artifacts", Access.at(0), "revision"], fn _ -> metadata.revision end)
      |> Jason.encode!()

    fetcher = fn _url -> DevIDE.Release.Update.Manifest.decode(same) end
    result = Check.run(fetch: fetcher)
    assert result.status == :current
  end

  test "run reports error when fetch fails", %{fetcher: _fetcher} do
    fetcher = fn _url -> {:error, {:http_status, 404}} end
    result = Check.run(fetch: fetcher)
    assert result.status == :error
    assert result.message =~ "404"
  end

  defp decode_manifest do
    {:ok, manifest} = DevIDE.Release.Update.Manifest.decode(@manifest_json)
    manifest
  end
end
