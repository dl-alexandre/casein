defmodule Casein.Release.MetadataTest do
  use ExUnit.Case, async: true

  alias Casein.Release.Metadata

  @valid %{
    "metadata_version" => 1,
    "app" => "devide",
    "version" => "0.1.0",
    "revision" => "504670cdeadbeef",
    "profile" => "lan",
    "repo_adapter" => "sqlite",
    "target" => "linux-x86_64",
    "channel" => "canary",
    "update_manifest_url" => "https://example.com/devide-canary.json",
    "built_at" => "2026-07-02T12:00:00Z"
  }

  setup do
    tmp = System.tmp_dir!() |> Path.join("devide-relmeta-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "validate accepts v1 metadata" do
    assert :ok = Metadata.validate(@valid)
  end

  test "validate rejects unsupported metadata version" do
    assert {:error, {:unsupported_metadata_version, 2}} =
             Metadata.validate(Map.put(@valid, "metadata_version", 2))
  end

  test "write and read round-trip", %{tmp: tmp} do
    metadata =
      Metadata.build_for_assemble(
        revision: "abc123",
        profile: "lan",
        repo_adapter: "sqlite",
        target: "linux-x86_64"
      )

    :ok = Metadata.write!(tmp, metadata)
    assert File.exists?(Path.join(tmp, Metadata.relative_path()))
    assert {:ok, read} = Metadata.read(tmp)
    assert read.revision == "abc123"
    assert read.profile == "lan"
  end

  test "manifest_url prefers env override" do
    metadata =
      Metadata.build_for_assemble(update_manifest_url: "https://embedded.example/manifest.json")

    prev = System.get_env("DEVIDE_UPDATE_MANIFEST_URL")
    System.put_env("DEVIDE_UPDATE_MANIFEST_URL", "https://override.example/manifest.json")
    on_exit(fn -> restore_env("DEVIDE_UPDATE_MANIFEST_URL", prev) end)

    assert Metadata.manifest_url(metadata) == "https://override.example/manifest.json"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
