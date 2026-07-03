defmodule DevIDE.Release.Update.InstallPlan do
  @moduledoc """
  Read-only planning helpers for release-side LAN update installs.

  The root-only `bin/devide` wrapper owns downloads, extraction, symlink swaps,
  service restarts, and rollback. This module keeps manifest parsing and
  compatibility checks in Elixir where structured data is already available.
  """

  alias DevIDE.Release.Metadata
  alias DevIDE.Release.Update.Manifest

  @type result ::
          {:ok, :current, Metadata.t(), Manifest.artifact(), Manifest.t(), String.t()}
          | {:ok, :update_available, Metadata.t(), Manifest.artifact(), Manifest.t(), String.t()}
          | {:error, term()}

  @doc "Build an install plan for the release rooted at `release_root`."
  @spec build(Path.t(), keyword()) :: result()
  def build(release_root, opts \\ []) when is_binary(release_root) do
    requested_revision = Keyword.get(opts, :to)
    fetcher = Keyword.get(opts, :fetch, &Manifest.fetch/1)

    with {:ok, current} <- Metadata.read(release_root),
         manifest_url <- Metadata.manifest_url(current),
         {:ok, manifest} <- safe_fetch(fetcher, manifest_url),
         {:ok, artifact} <- Manifest.select_artifact(manifest, current),
         :ok <- validate_requested_revision(artifact, requested_revision) do
      status =
        if same_revision?(current.revision, artifact.revision),
          do: :current,
          else: :update_available

      {:ok, status, current, artifact, manifest, manifest_url}
    end
  end

  @doc """
  Print shell assignments for the release wrapper.

  Arguments are base64 encoded so shell quoting never affects the release root
  or requested revision values.
  """
  @spec print_shell_base64(String.t(), String.t()) :: non_neg_integer()
  def print_shell_base64(encoded_release_root, encoded_to) do
    release_root = decode64!(encoded_release_root)
    requested_revision = encoded_to |> decode64!() |> blank_to_nil()

    case build(release_root, to: requested_revision) do
      {:ok, status, current, artifact, manifest, manifest_url} ->
        print_plan(status, current, artifact, manifest, manifest_url)
        0

      {:error, reason} ->
        IO.puts(:stderr, "error: #{format_error(reason)}")
        1
    end
  end

  @doc "Print release metadata as shell assignments for the wrapper."
  @spec print_metadata_shell_base64(String.t()) :: non_neg_integer()
  def print_metadata_shell_base64(encoded_release_root) do
    release_root = decode64!(encoded_release_root)

    case Metadata.read(release_root) do
      {:ok, metadata} ->
        print_metadata("METADATA", metadata)
        0

      {:error, reason} ->
        IO.puts(:stderr, "error: #{format_error(reason)}")
        1
    end
  end

  defp safe_fetch(fetcher, url) do
    fetcher.(url)
  rescue
    exception -> {:error, {:fetch_failed, exception}}
  end

  defp validate_requested_revision(_artifact, nil), do: :ok

  defp validate_requested_revision(artifact, requested) do
    artifact_revision = normalize_revision(artifact.revision)
    requested = normalize_revision(requested)

    if String.starts_with?(artifact_revision, requested) do
      :ok
    else
      {:error,
       {:requested_revision_unavailable, %{requested: requested, available: artifact.revision}}}
    end
  end

  defp same_revision?(left, right) do
    normalize_revision(left) == normalize_revision(right)
  end

  defp normalize_revision(revision) when is_binary(revision) do
    revision
    |> String.trim()
    |> String.downcase()
  end

  defp print_plan(status, current, artifact, manifest, manifest_url) do
    IO.puts("PLAN_STATUS=#{status}")
    IO.puts("MANIFEST_CHANNEL_B64=#{encode64(manifest.channel)}")
    IO.puts("MANIFEST_URL_B64=#{encode64(manifest_url)}")
    print_metadata("CURRENT", current)
    print_artifact("ARTIFACT", artifact)
  end

  defp print_metadata(prefix, metadata) do
    IO.puts("#{prefix}_APP_B64=#{encode64(metadata.app)}")
    IO.puts("#{prefix}_VERSION_B64=#{encode64(metadata.version)}")
    IO.puts("#{prefix}_REVISION_B64=#{encode64(metadata.revision)}")
    IO.puts("#{prefix}_PROFILE_B64=#{encode64(metadata.profile)}")
    IO.puts("#{prefix}_REPO_ADAPTER_B64=#{encode64(metadata.repo_adapter)}")
    IO.puts("#{prefix}_TARGET_B64=#{encode64(metadata.target)}")
    IO.puts("#{prefix}_CHANNEL_B64=#{encode64(metadata.channel)}")
  end

  defp print_artifact(prefix, artifact) do
    IO.puts("#{prefix}_APP_B64=#{encode64(artifact.app)}")
    IO.puts("#{prefix}_VERSION_B64=#{encode64(artifact.version)}")
    IO.puts("#{prefix}_REVISION_B64=#{encode64(artifact.revision)}")
    IO.puts("#{prefix}_PROFILE_B64=#{encode64(artifact.profile)}")
    IO.puts("#{prefix}_REPO_ADAPTER_B64=#{encode64(artifact.repo_adapter)}")
    IO.puts("#{prefix}_TARGET_B64=#{encode64(artifact.target)}")
    IO.puts("#{prefix}_URL_B64=#{encode64(artifact.url)}")
    IO.puts("#{prefix}_SHA256_B64=#{encode64(artifact.sha256)}")
    IO.puts("#{prefix}_SIZE=#{artifact.size}")
  end

  defp encode64(value) when is_binary(value), do: Base.encode64(value)
  defp encode64(nil), do: ""

  defp decode64!(""), do: ""
  defp decode64!(value), do: Base.decode64!(value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp format_error({:http_status, status}), do: "manifest fetch failed with HTTP #{status}"
  defp format_error({:request_failed, reason}), do: "manifest fetch failed: #{inspect(reason)}"
  defp format_error({:invalid_json, _}), do: "manifest response was not valid JSON"

  defp format_error({:unsupported_manifest_version, version}),
    do: "unsupported manifest version #{inspect(version)}"

  defp format_error({:unsupported_metadata_version, version}),
    do: "unsupported metadata version #{inspect(version)}"

  defp format_error({:no_matching_artifact, info}),
    do: "no artifact for #{info.profile}/#{info.target}"

  defp format_error({:ambiguous_artifact, count}),
    do: "manifest listed #{count} matching artifacts"

  defp format_error({:incompatible_installer, info}),
    do: "installer too old for manifest (need metadata v#{info.required})"

  defp format_error({:requested_revision_unavailable, info}),
    do: "requested revision #{info.requested} is not available; manifest has #{info.available}"

  defp format_error({:missing_fields, fields}),
    do: "metadata missing #{Enum.join(fields, ", ")}"

  defp format_error(:enoent), do: "metadata file not found"
  defp format_error(reason), do: "update install planning failed: #{inspect(reason)}"
end
