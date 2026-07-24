defmodule Casein.Agents.PreviewTools.ControlSession.Playback do
  @moduledoc false

  alias Casein.Agents.PreviewTools.ControlSession.Shared
  alias Casein.Agents.PreviewTools.ControlSession.SessionResolve
  alias Casein.Agents.PreviewTools.ControlSession.PaneOpen
  alias Casein.Agents.PreviewTools.TmuxTopology, as: PreviewTmuxTopology
  alias Casein.Previews.Url

  @doc "Open a saved recording artifact as playback in a fresh preview pane."
  @spec playback_open(map(), map()) :: {:ok, map()} | {:error, term()}
  def playback_open(workspace, params) when is_map(workspace) and is_map(params) do
    with {:ok, artifact_path} <- Shared.required_string(params, :artifact_path),
         {:ok, artifact_path} <- playback_artifact_path(workspace, artifact_path),
         {:ok, playback_url} <- playback_artifact_url(artifact_path, params),
         :ok <- SessionResolve.ensure_unambiguous_tmux_session(workspace, params),
         opts <- SessionResolve.split_opts(params, workspace),
         {:ok, result} <- PaneOpen.split_preview_pane(workspace, playback_url, opts) do
      payload =
        result.session
        |> Shared.session_payload()
        |> Map.put(:pane_id, result.pane_id)
        |> Map.put(:artifact_path, artifact_path)
        |> Map.put(:playback_url, playback_url)
        |> Map.put(:loop, playback_loop?(params))
        |> Map.put(:placement, PreviewTmuxTopology.placement_payload(result.registration))
        |> Shared.put_preview_next("preview_observe_pane", %{pane_id: result.pane_id})

      {:ok, payload}
    end
  end

  defp playback_artifact_path(workspace, artifact_path) when is_binary(artifact_path) do
    path = URI.parse(artifact_path).path || ""
    workspace_id = Shared.workspace_id(workspace)

    with {:ok, decoded_path} <- decode_artifact_path(path) do
      prefix = "/preview-artifacts/#{workspace_id}/"
      ext = decoded_path |> Path.extname() |> String.downcase()
      filename = String.replace_prefix(decoded_path, prefix, "")

      cond do
        not is_binary(workspace_id) or workspace_id == "" ->
          {:error, :workspace_id_required}

        String.contains?(decoded_path, ["\r", "\n"]) ->
          {:error, invalid_playback_artifact_error(artifact_path, workspace_id)}

        not String.starts_with?(decoded_path, prefix) ->
          {:error, invalid_playback_artifact_error(artifact_path, workspace_id)}

        filename == "" or String.contains?(filename, ["/", "\\", ".."]) ->
          {:error, invalid_playback_artifact_error(artifact_path, workspace_id)}

        ext not in [".webm", ".mp4"] ->
          {:error,
           %{
             error: :unsupported_playback_artifact,
             artifact_path: artifact_path,
             allowed_extensions: [".webm", ".mp4"],
             message: "preview_playback_open only supports saved webm/mp4 recording artifacts."
           }}

        true ->
          {:ok, decoded_path}
      end
    else
      {:error, :invalid_artifact_path_encoding} ->
        {:error, invalid_playback_artifact_error(artifact_path, workspace_id)}
    end
  end

  defp decode_artifact_path(path) do
    {:ok, URI.decode(path)}
  rescue
    ArgumentError -> {:error, :invalid_artifact_path_encoding}
  end

  defp playback_artifact_url(artifact_path, params) do
    with {:ok, origin} <- playback_origin() do
      {:ok, origin <> artifact_path <> "?" <> playback_query(playback_loop?(params))}
    end
  end

  defp playback_origin do
    base_url = Application.get_env(:casein, :preview_app_url) || Shared.preview_api_base_url()

    case Url.origin_of(base_url) do
      origin when is_binary(origin) and origin != "" ->
        {:ok, origin}

      _ ->
        {:error,
         %{
           error: :missing_preview_app_url,
           message:
             "preview_playback_open needs DEVIDE_URL, PHX_HOST, or :preview_app_url to build the artifact playback URL."
         }}
    end
  end

  defp playback_query(true), do: URI.encode_query([{"fit", "playback"}, {"loop", "1"}])
  defp playback_query(false), do: URI.encode_query([{"fit", "playback"}])

  defp playback_loop?(params), do: Shared.boolean_param(params, :loop) != false

  defp invalid_playback_artifact_error(artifact_path, workspace_id) do
    %{
      error: :invalid_playback_artifact,
      artifact_path: artifact_path,
      workspace_id: workspace_id,
      message:
        "artifact_path must be a traversal-free /preview-artifacts/#{workspace_id}/...webm or .mp4 path."
    }
  end

end
