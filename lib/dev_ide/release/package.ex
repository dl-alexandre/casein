defmodule DevIDE.Release.Package do
  @moduledoc """
  Local LAN release packaging helpers — tarball manifest emission for `dist/`.

  See `docs/lan-release-updates.md` and `scripts/package-release.sh`.
  """

  alias DevIDE.Release.Metadata
  alias DevIDE.Release.Update.Manifest

  @default_channel "canary"
  @github_repo "dl-alexandre/dev_ide"

  @type write_opts :: [
          release_root: Path.t(),
          tarball: Path.t(),
          dist_dir: Path.t(),
          channel: String.t(),
          previous_revision: String.t() | nil
        ]

  @doc """
  Upsert a packaged artifact into `dist/devide-<channel>.json` and return paths.
  """
  @spec write_dist_manifest!(write_opts()) :: %{manifest_path: Path.t(), artifact: map()}
  def write_dist_manifest!(opts) do
    release_root = Keyword.fetch!(opts, :release_root)
    tarball = Keyword.fetch!(opts, :tarball)
    dist_dir = Keyword.get(opts, :dist_dir, "dist")
    channel = Keyword.get(opts, :channel, @default_channel)
    previous_revision = Keyword.get(opts, :previous_revision)

    {:ok, metadata} = Metadata.read(release_root)

    sha256 = sha256_hex(tarball)
    size = File.stat!(tarball).size
    short_revision = short_revision(metadata.revision)

    artifact = %{
      "app" => metadata.app,
      "version" => metadata.version,
      "revision" => metadata.revision,
      "profile" => metadata.profile,
      "repo_adapter" => metadata.repo_adapter,
      "target" => metadata.target,
      "url" => artifact_url(metadata, short_revision),
      "sha256" => sha256,
      "size" => size,
      "min_installer_metadata_version" => Metadata.supported_metadata_version(),
      "changelog_url" => changelog_url(previous_revision, metadata.revision)
    }

    manifest_path = Path.join(dist_dir, "devide-#{channel}.json")
    manifest = load_manifest(manifest_path, channel)
    updated = upsert_artifact(manifest, artifact)

    File.mkdir_p!(dist_dir)
    File.write!(manifest_path, Jason.encode!(updated, pretty: true) <> "\n")

    %{manifest_path: manifest_path, artifact: artifact}
  end

  defp load_manifest(path, channel) do
    case File.read(path) do
      {:ok, body} ->
        case Manifest.decode(body) do
          {:ok, decoded} -> manifest_to_map(decoded)
          _ -> fresh_manifest(channel)
        end

      {:error, :enoent} ->
        fresh_manifest(channel)
    end
  end

  defp fresh_manifest(channel) do
    %{
      "manifest_version" => Manifest.supported_manifest_version(),
      "channel" => channel,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "signature" => nil,
      "artifacts" => []
    }
  end

  defp manifest_to_map(%{manifest_version: v, channel: c, generated_at: at, signature: sig, artifacts: arts}) do
    %{
      "manifest_version" => v,
      "channel" => c,
      "generated_at" => at,
      "signature" => sig,
      "artifacts" => Enum.map(arts, &artifact_to_map/1)
    }
  end

  defp artifact_to_map(artifact) do
    %{
      "app" => artifact.app,
      "version" => artifact.version,
      "revision" => artifact.revision,
      "profile" => artifact.profile,
      "repo_adapter" => artifact.repo_adapter,
      "target" => artifact.target,
      "url" => artifact.url,
      "sha256" => artifact.sha256,
      "size" => artifact.size,
      "min_installer_metadata_version" => artifact.min_installer_metadata_version,
      "changelog_url" => artifact.changelog_url
    }
  end

  defp upsert_artifact(%{"artifacts" => artifacts} = manifest, %{} = artifact) do
    key = {artifact["profile"], artifact["target"], artifact["app"]}

    artifacts =
      artifacts
      |> Enum.reject(fn entry ->
        {entry["profile"], entry["target"], entry["app"]} == key
      end)
      |> Kernel.++([artifact])

    manifest
    |> Map.put("generated_at", DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.put("artifacts", artifacts)
  end

  defp artifact_url(metadata, short_revision) do
    "https://github.com/#{@github_repo}/releases/download/#{metadata.channel}/devide-#{metadata.profile}-#{metadata.target}-#{short_revision}.tar.gz"
  end

  defp changelog_url(nil, _current), do: nil
  defp changelog_url("", _current), do: nil

  defp changelog_url(previous, current) do
    "https://github.com/#{@github_repo}/compare/#{previous}...#{current}"
  end

  defp sha256_hex(path) do
    path
    |> File.stream!(8192, [:read, :binary])
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp short_revision(revision) when is_binary(revision) do
    String.slice(revision, 0, 7)
  end
end