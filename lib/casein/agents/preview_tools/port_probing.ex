defmodule Casein.Agents.PreviewTools.PortProbing do
  @moduledoc false

  alias Casein.Agents.PreviewTools.{ControlSession, WorkspaceResolution}
  alias Casein.Agents.PreviewTools.ControlSession.SessionResolve
  alias Casein.Previews.Deps
  alias Casein.Previews.WorkspaceContext
  # Struct-only leaf (not in the runtime SCC).
  alias Casein.Runtimes.Runtime
  alias Casein.Terminals.TmuxScope

  @inactive_runtime_statuses ~w(cleaned expired)

  @doc "Ensure the runtime-owned preview server for the scoped agent session."
  @spec ensure_server_here(map(), map()) :: {:ok, map()} | {:error, term()}
  def ensure_server_here(workspace, params \\ %{}) do
    case resolve_tmux_session(workspace, params) do
      session when is_binary(session) ->
        start_runtime_preview_server(workspace, session)

      _ ->
        {:error, missing_tmux_session_error()}
    end
  end

  defp start_runtime_preview_server(workspace, session) do
    with {:ok, %Runtime{} = runtime} <- runtime_for_tmux_session(workspace, session),
         %{} = preview_server <- Deps.impl(:runtimes).runtime_preview_server(runtime),
         :ok <- Deps.impl(:runtimes).ensure_preview_server_started(runtime) do
      {:ok,
       %{
         status: "queued",
         workspace_id: runtime.workspace_id,
         runtime_id: runtime.id,
         tmux_session: session,
         preview_server: preview_server
       }}
    else
      nil ->
        {:error, :runtime_preview_server_missing}

      false ->
        {:error, :runtime_preview_server_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Open a localhost preview on an allowed port."
  @spec open_localhost_preview(map(), map()) :: {:ok, map()} | {:error, term()}
  def open_localhost_preview(workspace, params \\ %{}) when is_map(workspace) do
    with {:ok, port} <- parse_port(Map.get(params, "port") || Map.get(params, :port)),
         :ok <- WorkspaceContext.validate_port(WorkspaceResolution.prepare(workspace), port) do
      path = localhost_path(port, params)
      url = WorkspaceContext.localhost_url(port, path)
      ControlSession.open_localhost_url(workspace, params, url)
    end
  end

  def maybe_preflight_preview_url(url, opts) do
    if Keyword.get(opts, :preflight_done) == true do
      :ok
    else
      preflight_preview_url(url, opts)
    end
  end

  def preflight_preview_url(url, opts) do
    if preview_preflight_enabled?(opts) do
      do_preflight_preview_url(url, opts)
    else
      :ok
    end
  end

  defp preview_preflight_enabled?(opts) do
    Keyword.get(opts, :preflight) ||
      Application.get_env(:casein, :preview_open_preflight, true)
  end

  defp do_preflight_preview_url(url, opts) when is_binary(url) do
    headers = Keyword.get(opts, :default_headers) || %{}
    timeout = Application.get_env(:casein, :preview_open_preflight_timeout_ms, 1_500)

    case Req.get(url,
           headers: headers,
           redirect: false,
           retry: false,
           connect_options: [timeout: timeout],
           receive_timeout: timeout
         ) do
      {:ok, %{status: status}} when status in 200..399 or status in [401, 403] ->
        :ok

      # A stopped devbox workspace has no active Caddy route, so its public
      # subdomain falls through to Casein's preview-router, which answers 404
      # with this marker body (scripts/preview-router.sh). That is "the app
      # isn't running", NOT a bad URL — classify it distinctly so the caller
      # knows to start the workspace rather than fix the URL.
      {:ok, %{status: 404, body: body}}
      when is_binary(body) and body != "" ->
        if String.contains?(body, "No active preview environment") do
          {:error,
           %{
             error: :workspace_app_not_running,
             url: url,
             status: 404,
             message:
               "Workspace app is not running — the devbox preview-router returned " <>
                 "\"No active preview environment\" for #{url}. Start the workspace's app " <>
                 "(its dev server), then retry; no preview pane was opened."
           }}
        else
          preview_http_status_error(url, 404)
        end

      {:ok, %{status: status}} ->
        preview_http_status_error(url, status)

      {:error, reason} ->
        {:error,
         %{
           error: :preview_unreachable,
           url: url,
           reason: preview_preflight_reason(reason),
           message: "Preview URL is unreachable; no preview pane was opened."
         }}
    end
  end

  defp do_preflight_preview_url(url, _opts) do
    {:error,
     %{
       error: :invalid_preview_url,
       url: inspect(url),
       message: "Preview URL must be a string; no preview pane was opened."
     }}
  end

  defp preview_http_status_error(url, status) do
    {:error,
     %{
       error: :preview_http_status,
       url: url,
       status: status,
       message: "Preview URL responded with HTTP #{status}; no preview pane was opened."
     }}
  end

  defp preview_preflight_reason(%{reason: reason}), do: reason
  defp preview_preflight_reason(reason), do: inspect(reason)

  defp resolve_tmux_session(workspace, params) do
    SessionResolve.requested_tmux_session(params) ||
      SessionResolve.workspace_tmux_session(workspace)
  end

  defp runtime_for_tmux_session(workspace, tmux_session) do
    workspace_id = workspace_id(workspace)

    candidates =
      %{"workspace_id" => workspace_id}
      |> Deps.impl(:runtimes).list_runtimes()
      |> Enum.reject(fn
        %Runtime{status: status} -> status in @inactive_runtime_statuses
        _ -> true
      end)

    case pick_runtime(candidates, tmux_session, workspace) do
      %Runtime{} = runtime ->
        {:ok, runtime}

      _ ->
        {:error,
         %{
           error: :runtime_surface_not_found,
           tmux_session: tmux_session,
           workspace_id: workspace_id,
           message:
             "No runtime preview server is registered for this tmux_session. " <>
               "Pass the same session sibling preview tools accept " <>
               "(terminal_list_sessions name, or the workspace id/name alias of that session). " <>
               "Report the worktree runtime before opening a runtime preview if none is registered."
         }}
    end
  end

  defp pick_runtime(candidates, tmux_session, workspace) do
    scope = runtime_scope(workspace)

    cond do
      runtime = Enum.find(candidates, &(&1.tmux_session_id == tmux_session)) ->
        runtime

      runtime =
          Enum.find(
            candidates,
            &TmuxScope.equivalent_session?(&1.tmux_session_id, tmux_session, scope)
          ) ->
        runtime

      match?([_one], candidates) ->
        hd(candidates)

      true ->
        nil
    end
  end

  defp runtime_scope(%{id: id, name: name} = workspace)
       when is_binary(id) and is_binary(name) and name != "",
       do: workspace

  defp runtime_scope(workspace) do
    case workspace_id(workspace) do
      id when is_binary(id) -> id
      _ -> workspace
    end
  end

  defp localhost_path(port, params) do
    path = Map.get(params, "path", Map.get(params, :path, "/"))
    loopback_port = Application.get_env(:casein, :preview_loopback_port, 4000)

    if port == loopback_port and path in ["/", ""], do: "/workspaces", else: path
  end

  defp missing_tmux_session_error do
    %{
      error: :missing_tmux_session,
      message:
        "Pass tmux_session or use the session-scoped Preview MCP URL for the calling agent.",
      guidance:
        "Use the session-scoped MCP endpoint so tmux_session is injected automatically, or pass tmux_session from terminal_list_sessions."
    }
  end

  defp workspace_id(workspace),
    do: Map.get(workspace, :id) || Map.get(workspace, "id")

  defp parse_port(port) when is_integer(port), do: {:ok, port}

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_port}
    end
  end

  defp parse_port(_), do: {:error, :invalid_port}
end
