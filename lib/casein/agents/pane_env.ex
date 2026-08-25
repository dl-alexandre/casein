defmodule Casein.Agents.PaneEnv do
  @moduledoc """
  Builds the `CASEIN_*` environment (MCP URLs, API token, checkout, staging
  home) external agents need, and pushes it into a workspace tmux session via
  `Tmux.set_environments/2`. Materializes MCP client configs as a side effect.
  """

  alias Casein.Agents.{
    AgentShims,
    MCPMaterializer,
    MCPUrls,
    TidewaveMCP,
    WorkspaceTokens
  }

  alias Casein.Identity
  alias Casein.Terminals.Shims

  @doc """
  Build the environment map agents need for Casein MCP, keyed as strings.

  Pass `:viewer` (a `ForwardAuth` identity map) so provider homes and
  `GH_CONFIG_DIR` resolve to the person who triggered the launch rather than
  the workspace owner — see `Casein.Identity`. Without it the identity falls
  back to the workspace owner, which is what non-request callers want.
  """
  @spec vars_for_workspace(map(), keyword()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def vars_for_workspace(workspace, opts \\ []) when is_map(workspace) do
    with {:ok, token} <- WorkspaceTokens.for_agent(workspace),
         {:ok, staging} <- MCPMaterializer.materialize(workspace, opts) do
      workspace_id = workspace_id(workspace)
      workspace_name = workspace_name(workspace)
      checkout = Keyword.get(opts, :checkout) || workspace[:path] || workspace["path"] || ""
      scripts_root = scripts_root(checkout)
      env_sh = Path.join(staging, "env.sh")
      local_bin = AgentShims.bin_dir()
      npm_prefix = AgentShims.npm_prefix()
      npm_bin = AgentShims.npm_bin_dir()

      # Prefer agent launcher shims first so bare `claude`/`grok` always hit
      # Casein MCP injection; Shims.path_with_shims/1 also embeds these dirs so
      # session create (pre-PaneEnv) is not bashrc-dependent.
      path =
        case System.get_env("PATH") do
          p when is_binary(p) and p != "" ->
            path_uniq("#{local_bin}:#{npm_bin}:#{Shims.path_with_shims(p)}")

          _ ->
            path_uniq("#{local_bin}:#{npm_bin}:#{Shims.path_with_shims("")}")
        end

      vars =
        %{
          "CASEIN_API_TOKEN" => token,
          "CASEIN_WORKSPACE_ID" => workspace_id,
          "CASEIN_WORKSPACE_NAME" => workspace_name,
          "CASEIN_API_BASE_URL" => MCPUrls.api_base_url(),
          "CASEIN_TERMINAL_MCP_URL" => MCPUrls.terminal_url(workspace_id, opts),
          "CASEIN_PREVIEW_MCP_URL" => MCPUrls.preview_url(workspace_id, opts),
          "CASEIN_ARTIFACT_MCP_URL" => MCPUrls.artifact_url(workspace_id),
          "CASEIN_CHECKOUT" => checkout,
          "CASEIN_AGENT_MCP_HOME" => staging,
          "CASEIN_SCRIPTS" => scripts_root,
          "CASEIN_AGENT_ENV_FILE" => env_sh,
          "CASEIN_NPM_PREFIX" => npm_prefix,
          "PATH" => path
        }
        |> maybe_put_tmux_session(opts)
        |> maybe_put_tidewave(workspace, opts)
        |> Map.merge(identity_env(workspace, opts))

      {:ok, vars}
    end
  end

  # `env: false` — the identity must come from the caller or the workspace, never
  # from the release's own environment. A `CASEIN_ACTOR` inherited by the beam
  # would otherwise stamp every workspace on the box with one principal.
  defp identity_env(workspace, opts) do
    Identity.env(
      viewer: Keyword.get(opts, :viewer),
      principal: Keyword.get(opts, :principal),
      workspace: workspace,
      env: false
    )
  end

  @doc """
  Materialize MCP client configs and push workspace env into a tmux session.

  Self-heals missing agent launcher shims before pushing PATH so template
  apply / interactive launch do not leave `claude: command not found`.

  Also refreshes `:tmux_ctl` `:terminal_env` so the next `new-window` /
  `split-window` inherits agent bins via `-e PATH=…` even before this
  session map is applied.
  """
  @spec ensure_for_session(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def ensure_for_session(tmux_session, workspace, opts \\ [])
      when is_binary(tmux_session) and is_map(workspace) do
    # Publish host PATH with agent bins first — covers panes created in the
    # same tick as this call (template apply, after_mount race).
    _ = Shims.sync_tmux_terminal_env!()

    case vars_for_workspace(workspace, Keyword.put_new(opts, :tmux_session, tmux_session)) do
      {:ok, vars} ->
        with :ok <- maybe_set_session_actor(tmux_session, Map.get(vars, "CASEIN_ACTOR")),
             :ok <- tmux_adapter().set_environments(tmux_session, vars) do
          :ok
        end

      {:error, _} = error ->
        error
    end
  end

  defp maybe_set_session_actor(_tmux_session, actor) when actor in [nil, ""], do: :ok

  defp maybe_set_session_actor(tmux_session, actor) when is_binary(actor) do
    adapter = tmux_adapter()

    if function_exported?(adapter, :set_session_actor, 2) do
      adapter.set_session_actor(tmux_session, actor)
    else
      :ok
    end
  end

  @doc """
  Rotate the workspace API bearer and push the new grant into live tmux sessions.

  Steps:

  1. `WorkspaceTokens.rotate_for/1` — mint + retire previous bearer
  2. Rematerialize MCP client configs / `env.sh` with the new token
  3. `tmux set-environment` on every matching workspace session so new panes
     and shell integrations that re-sync pick up `CASEIN_API_TOKEN`

  Running agent *processes* that already expanded the bearer into memory
  (managed Grok `grokcap_*` cache, some MCP client bootstraps) cannot be
  rewritten in-place — those keep calling with the retired token and receive
  an explicit `stale_grant` from API auth until relaunch. Shell-backed panes
  that re-export session env (Casein shell integration) rebound without
  relaunch.

  Returns `{:ok, %{token, previous_token, sessions}}`.
  """
  @spec rebind_workspace(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def rebind_workspace(workspace, opts \\ []) when is_map(workspace) do
    workspace_id = workspace_id(workspace)

    with true <- workspace_id != "" || {:error, :workspace_id_missing},
         {:ok, token, previous} <- WorkspaceTokens.rotate_for(workspace_id),
         sessions <- target_sessions(workspace, opts),
         :ok <- push_sessions(sessions, workspace, opts) do
      {:ok,
       %{
         workspace_id: workspace_id,
         token: token,
         previous_token: previous,
         sessions: sessions,
         rebound: sessions != [],
         note: rebind_note(sessions, previous)
       }}
    end
  end

  @doc """
  Push the current workspace bearer into one tmux session without rotating.

  Use after an external rotation (or to heal a session that missed the last
  `ensure_for_session/3`). Prefer `rebind_workspace/2` when the secret itself
  must change.
  """
  @spec rebind_for_session(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def rebind_for_session(tmux_session, workspace, opts \\ [])
      when is_binary(tmux_session) and is_map(workspace) do
    ensure_for_session(tmux_session, workspace, opts)
  end

  defp target_sessions(workspace, opts) do
    case Keyword.get(opts, :tmux_session) do
      session when is_binary(session) and session != "" ->
        [session]

      _ ->
        workspace_id = workspace_id(workspace)
        workspace_name = workspace_name(workspace)

        prefixes =
          [workspace_id, workspace_name]
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.map(&Casein.Terminals.tmux_workspace_session_prefix/1)
          |> Enum.uniq()

        tmux_adapter().list_sessions()
        |> Enum.map(fn
          %{session: name} when is_binary(name) -> name
          name when is_binary(name) -> name
          _ -> nil
        end)
        |> Enum.filter(
          &(is_binary(&1) and Enum.any?(prefixes, fn p -> String.starts_with?(&1, p) end))
        )
        |> Enum.uniq()
    end
  end

  defp push_sessions([], _workspace, _opts), do: :ok

  defp push_sessions(sessions, workspace, opts) do
    Enum.reduce_while(sessions, :ok, fn session, :ok ->
      case ensure_for_session(session, workspace, Keyword.put(opts, :tmux_session, session)) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp rebind_note([], _previous) do
    "token rotated; no live tmux sessions matched — new panes will pick up the grant on ensure"
  end

  defp rebind_note(_sessions, previous) when is_binary(previous) do
    "token rotated and pushed to session env; shell integrations re-export CASEIN_API_TOKEN. " <>
      "Managed Grok grokcap_* caches and process-frozen MCP clients report stale_grant until relaunch."
  end

  defp rebind_note(_sessions, _previous) do
    "token minted and pushed to session env"
  end

  @doc """
  Command to send to a raw terminal pane when launching an interactive agent.

  Agent binaries on PATH are shimmed (grok, claude, codex, …) so the bare
  command name is enough — MCP injection happens automatically.

  `clauded` is a host bash alias (`claude --dangerously-skip-permissions`).
  Palette/MCP launches must not rely on that alias: the Casein `claude` shim
  already defaults to skip-permissions via `launch-casein-agent.sh`.
  """
  @spec launch_command(String.t(), map(), keyword()) :: String.t()
  def launch_command(runtime_id, _workspace, _opts \\ [])
      when is_binary(runtime_id) do
    case String.trim(runtime_id) do
      "clauded" -> "claude"
      other -> other
    end
  end

  defp scripts_root(checkout) when checkout in [nil, ""], do: ""

  defp scripts_root(checkout) when is_binary(checkout) do
    candidate = Path.join(checkout, "scripts")

    if File.regular?(Path.join(candidate, "casein")) do
      candidate
    else
      Application.get_env(:casein, :agent_scripts_path) ||
        non_empty_env("CASEIN_SCRIPTS") ||
        candidate
    end
  end

  defp workspace_id(workspace) do
    Map.get(workspace, :id) || Map.get(workspace, "id") || ""
  end

  defp workspace_name(workspace) do
    Map.get(workspace, :name) || Map.get(workspace, "name") || workspace_id(workspace)
  end

  defp path_uniq(path) when is_binary(path) do
    path
    |> String.split(":", trim: true)
    |> Enum.uniq()
    |> Enum.join(":")
  end

  defp non_empty_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp maybe_put_tmux_session(vars, opts) do
    case Keyword.get(opts, :tmux_session) do
      session when is_binary(session) and session != "" ->
        Map.put(vars, "CASEIN_TMUX_SESSION", session)

      _ ->
        vars
    end
  end

  defp maybe_put_tidewave(vars, workspace, opts) do
    case TidewaveMCP.resolve_url(workspace, opts) do
      url when is_binary(url) -> Map.put(vars, "CASEIN_TIDEWAVE_MCP_URL", url)
      _ -> vars
    end
  end

  defp tmux_adapter, do: Casein.Terminals.tmux_adapter()
end
