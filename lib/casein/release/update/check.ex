defmodule Casein.Release.Update.Check do
  @moduledoc """
  Compare installed release metadata against a remote update manifest.

  `revision` is the update key; `version` is display-only.
  """

  alias Casein.Release.Metadata
  alias Casein.Release.Update.Manifest

  @type status :: :current | :update_available | :error

  @type result :: %{
          status: status(),
          current: Metadata.t(),
          available: Manifest.artifact() | nil,
          manifest: Manifest.t() | nil,
          manifest_url: String.t() | nil,
          message: String.t()
        }

  @doc "Run an update check against the installed release."
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    fetcher = Keyword.get(opts, :fetch, &Manifest.fetch/1)

    with {:ok, current, _root} <- Metadata.load_current(),
         manifest_url <- Metadata.manifest_url(current),
         {:ok, manifest} <- safe_fetch(fetcher, manifest_url),
         {:ok, artifact} <- Manifest.select_artifact(manifest, current) do
      if same_revision?(current.revision, artifact.revision) do
        current_result(current, manifest, manifest_url, artifact)
      else
        update_available_result(current, manifest, manifest_url, artifact)
      end
    else
      {:error, reason} ->
        error_result(reason)
    end
  end

  defp safe_fetch(fetcher, url) do
    fetcher.(url)
  rescue
    exception -> {:error, {:fetch_failed, exception}}
  end

  defp same_revision?(left, right) do
    normalize_revision(left) == normalize_revision(right)
  end

  defp normalize_revision(revision) when is_binary(revision) do
    revision
    |> String.trim()
    |> String.downcase()
  end

  defp current_result(current, manifest, manifest_url, artifact) do
    %{
      status: :current,
      current: current,
      available: artifact,
      manifest: manifest,
      manifest_url: manifest_url,
      message:
        "Running revision #{short_revision(current.revision)} is current for #{manifest.channel}."
    }
  end

  defp update_available_result(current, manifest, manifest_url, artifact) do
    %{
      status: :update_available,
      current: current,
      available: artifact,
      manifest: manifest,
      manifest_url: manifest_url,
      message:
        "Update available: #{short_revision(current.revision)} -> #{short_revision(artifact.revision)} on #{manifest.channel}."
    }
  end

  defp error_result(reason) do
    case Metadata.load_current() do
      {:ok, current, _} ->
        %{
          status: :error,
          current: current,
          available: nil,
          manifest: nil,
          manifest_url: Metadata.manifest_url(current),
          message: format_error(reason)
        }

      {:error, _} ->
        %{
          status: :error,
          current: nil,
          available: nil,
          manifest: nil,
          manifest_url: System.get_env("DEVIDE_UPDATE_MANIFEST_URL"),
          message: format_error(reason)
        }
    end
  end

  defp short_revision(revision) when is_binary(revision) do
    String.slice(revision, 0, 7)
  end

  defp format_error({:http_status, status}), do: "Manifest fetch failed with HTTP #{status}."
  defp format_error({:request_failed, reason}), do: "Manifest fetch failed: #{inspect(reason)}."
  defp format_error({:invalid_json, _}), do: "Manifest response was not valid JSON."

  defp format_error({:unsupported_manifest_version, version}),
    do: "Unsupported manifest version #{inspect(version)}."

  defp format_error({:no_matching_artifact, info}),
    do: "No artifact for #{info.profile}/#{info.target}."

  defp format_error({:ambiguous_artifact, count}),
    do: "Manifest listed #{count} matching artifacts."

  defp format_error({:incompatible_installer, info}),
    do: "Installer too old for manifest (need metadata v#{info.required})."

  defp format_error({:missing_fields, fields}),
    do: "Installed metadata missing #{Enum.join(fields, ", ")}."

  defp format_error(:enoent), do: "Installed metadata file not found."
  defp format_error(reason), do: "Update check failed: #{inspect(reason)}"
end
