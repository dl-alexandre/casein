defmodule DevIDE.Release.PackageTest do
  use ExUnit.Case, async: false

  alias DevIDE.Release.Metadata
  alias DevIDE.Release.Package

  setup do
    tmp = System.tmp_dir!() |> Path.join("devide-package-#{System.unique_integer([:positive])}")
    release_root = Path.join(tmp, "release-out")
    dist_dir = Path.join(tmp, "dist")
    File.mkdir_p!(release_root)
    File.mkdir_p!(dist_dir)

    metadata =
      Metadata.build_for_assemble(
        revision: "67f393adeadbeef0123456789abcdef012345678",
        profile: "lan",
        repo_adapter: "sqlite",
        target: "linux-x86_64",
        channel: "canary"
      )

    :ok = Metadata.write!(release_root, metadata)

    tarball = Path.join(dist_dir, "devide-lan-linux-x86_64-67f393a.tar.gz")
    File.write!(tarball, "fake tarball bytes for hashing")

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{release_root: release_root, dist_dir: dist_dir, tarball: tarball, metadata: metadata}
  end

  test "write_dist_manifest! upserts artifact into channel manifest", %{
    release_root: release_root,
    dist_dir: dist_dir,
    tarball: tarball,
    metadata: metadata
  } do
    %{manifest_path: path, artifact: art} =
      Package.write_dist_manifest!(
        release_root: release_root,
        tarball: tarball,
        dist_dir: dist_dir,
        channel: "canary",
        previous_revision: "504670cdeadbeef"
      )

    assert path == Path.join(dist_dir, "devide-canary.json")
    assert art["revision"] == metadata.revision
    assert art["profile"] == "lan"
    assert art["target"] == "linux-x86_64"
    assert is_binary(art["sha256"])
    assert art["size"] == byte_size("fake tarball bytes for hashing")
    assert art["url"] =~ "devide-lan-linux-x86_64-67f393a.tar.gz"

    {:ok, body} = File.read(path)
    {:ok, decoded} = Jason.decode(body)
    assert decoded["channel"] == "canary"
    assert length(decoded["artifacts"]) == 1
    assert decoded["artifacts"] |> hd() |> Map.get("changelog_url") =~ "504670c"
  end
end