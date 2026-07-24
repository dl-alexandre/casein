defmodule Casein.Agents.PaneEnv do
  @moduledoc """
  Builds the `DEVIDE_*` environment (MCP URLs, API token, checkout, staging
  home) external agents need, and pushes it into a workspace tmux session via
  `Tmux.set_environments/2`. Materializes MCP client configs as a side effect.
  """

  alias Casein.Agents.{
    AgentShims,
    AuthProfile,
    MCPMaterializer,
    MCPUrls,
    TidewaveMCP,
    WorkspaceTokens
  }

  alias Casein.Terminals.{Shims, Tmux}

  @doc """
  Build the environment map agents need for Casein MCP, keyed as strings.
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
          "DEV_IDE_API_TOKEN" => token,
          "DEVIDE_WORKSPACE_ID" => workspace_id,
          "DEVIDE_WORKSPACE_NAME" => workspace_name,
          "DEVIDE_API_BASE_URL" => MCPUrls.api_base_url(),
          "DEVIDE_TERMINAL_MCP_URL" => MCPUrls.terminal_url(workspace_id, opts),
          "DEVIDE_PREVIEW_MCP_URL" => MCPUrls.preview_url(workspace_id, opts),
          "DEVIDE_ARTIFACT_MCP_URL" => MCPUrls.artifact_url(workspace_id),
          "DEVIDE_CHECKOUT" => checkout,
          "DEVIDE_AGENT_MCP_HOME" => staging,
          "DEVIDE_SCRIPTS" => scripts_root,
          "DEVIDE_AGENT_ENV_FILE" => env_sh,
          "DEV_IDE_NPM_PREFIX" => npm_prefix,
          "PATH" => path
        }
        |> maybe_put_tmux_session(opts)
        |> maybe_put_tidewave(workspace, opts)
        |> Map.merge(AuthProfile.env_for_workspace(workspace))

      {:ok, vars}
    end
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
        tmux_adapter().set_environments(tmux_session, vars)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Command to send to a raw terminal pane when launching an interactive agent.

  Agent binaries on PATH are shimmed (grok, claude, codex, …) so the bare
  command name is enough — MCP injection happens automatically.

  `clauded` is a host bash alias (`claude --dangerously-skip-permissions`).
  Palette/MCP launches must not rely on that alias: the Casein `claude` shim
  already defaults to skip-permissions via `launch-devide-agent.sh`.
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

    if File.regular?(Path.join(candidate, "devide")) do
      candidate
    else
      Application.get_env(:dev_ide, :agent_scripts_path) ||
        non_empty_env("DEVIDE_SCRIPTS") ||
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
        Map.put(vars, "DEVIDE_TMUX_SESSION", session)

      _ ->
        vars
    end
  end

  defp maybe_put_tidewave(vars, workspace, opts) do
    case TidewaveMCP.resolve_url(workspace, opts) do
      url when is_binary(url) -> Map.put(vars, "DEVIDE_TIDEWAVE_MCP_URL", url)
      _ -> vars
    end
  end

  defp tmux_adapter, do: Application.get_env(:dev_ide, :tmux_adapter, Tmux)
end
