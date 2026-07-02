defmodule DevIDE.Release.Update.Manifest do
  @moduledoc """
  Parser for channel-scoped LAN update manifests.

  See `docs/lan-release-updates.md`.
  """

  alias DevIDE.Release.Metadata

  @manifest_version 1

  @type artifact :: %{
          app: String.t(),
          version: String.t(),
          revision: String.t(),
          profile: String.t(),
          repo_adapter: String.t(),
          target: String.t(),
          url: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          min_installer_metadata_version: pos_integer(),
          changelog_url: String.t() | nil
        }

  @type t :: %{
          manifest_version: pos_integer(),
          channel: String.t(),
          generated_at: String.t(),
          signature: term(),
          artifacts: [artifact()]
        }

  @doc false
  @spec supported_manifest_version() :: pos_integer()
  def supported_manifest_version, do: @manifest_version

  @doc "Decode manifest JSON."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(body) when is_binary(body) do
    with {:ok, map} <- Jason.decode(body),
         :ok <- validate(map) do
      {:ok, normalize(map)}
    else
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fetch and decode a manifest from HTTPS."
  @spec fetch(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def fetch(url, opts \\ []) when is_binary(url) do
    req_opts = Keyword.merge([receive_timeout: 15_000], Keyword.take(opts, [:receive_timeout]))

    with {:ok, _apps} <- Application.ensure_all_started(:req) do
      case Req.get(url, req_opts) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          decode(body)

        {:ok, %{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    else
      {:error, reason} -> {:error, {:request_failed, reason}}
    end
  end

  @doc "Select the artifact matching installed metadata profile + target."
  @spec select_artifact(t(), Metadata.t()) :: {:ok, artifact()} | {:error, term()}
  def select_artifact(%{artifacts: artifacts}, metadata) do
    matches =
      Enum.filter(artifacts, fn artifact ->
        artifact.profile == metadata.profile and artifact.target == metadata.target and
          artifact.app == metadata.app
      end)

    case matches do
      [artifact] ->
        if compatible_installer?(artifact) do
          {:ok, artifact}
        else
          {:error,
           {:incompatible_installer,
            %{
              required: artifact.min_installer_metadata_version,
              supported: Metadata.supported_metadata_version()
            }}}
        end

      [] ->
        {:error,
         {:no_matching_artifact,
          %{profile: metadata.profile, target: metadata.target, app: metadata.app}}}

      _ ->
        {:error, {:ambiguous_artifact, length(matches)}}
    end
  end

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(map) when is_map(map) do
    cond do
      map["manifest_version"] != @manifest_version ->
        {:error, {:unsupported_manifest_version, map["manifest_version"]}}

      not is_binary(map["channel"]) ->
        {:error, :missing_channel}

      not is_list(map["artifacts"]) ->
        {:error, :missing_artifacts}

      true ->
        validate_artifacts(map["artifacts"])
    end
  end

  defp validate_artifacts(artifacts) do
    Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
      case validate_artifact(artifact) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_artifact(artifact) when is_map(artifact) do
    required =
      ~w(app version revision profile repo_adapter target url sha256 size
         min_installer_metadata_version)

    missing = Enum.reject(required, &Map.has_key?(artifact, &1))

    cond do
      missing != [] ->
        {:error, {:artifact_missing_fields, missing}}

      not is_integer(artifact["size"]) or artifact["size"] < 0 ->
        {:error, :invalid_artifact_size}

      true ->
        :ok
    end
  end

  defp validate_artifact(_), do: {:error, :invalid_artifact}

  defp compatible_installer?(artifact) do
    artifact.min_installer_metadata_version <= Metadata.supported_metadata_version()
  end

  defp normalize(map) do
    %{
      manifest_version: map["manifest_version"],
      channel: map["channel"],
      generated_at: map["generated_at"] || "",
      signature: map["signature"],
      artifacts: Enum.map(map["artifacts"], &normalize_artifact/1)
    }
  end

  defp normalize_artifact(map) do
    %{
      app: map["app"],
      version: map["version"],
      revision: map["revision"],
      profile: map["profile"],
      repo_adapter: map["repo_adapter"],
      target: map["target"],
      url: map["url"],
      sha256: map["sha256"],
      size: map["size"],
      min_installer_metadata_version: map["min_installer_metadata_version"],
      changelog_url: map["changelog_url"]
    }
  end
end
