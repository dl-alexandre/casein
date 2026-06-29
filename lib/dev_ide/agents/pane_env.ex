defmodule DevIDE.Agents.PaneEnv do
  @moduledoc """
  Builds the `DEVIDE_*` environment (MCP URLs, API token, checkout, staging
  home) external agents need, and pushes it into a workspace tmux session via
  `Tmux.set_environments/2`. Materializes MCP client configs as a side effect.
  """

  alias DevIDE.Agents.{MCPMaterializer, MCPUrls, TidewaveMCP}
  alias DevIDE.Terminals.{Shims, Tmux}

  @doc """
  Build the environment map agents need for DevIDE MCP, keyed as strings.
  """
  @spec vars_for_workspace(map(), keyword()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def vars_for_workspace(workspace, opts \\ []) when is_map(workspace) do
    with {:ok, token} <- api_token(),
         {:ok, staging} <- MCPMaterializer.materialize(workspace, opts) do
      workspace_id = workspace_id(workspace)
      workspace_name = workspace_name(workspace)
      checkout = Keyword.get(opts, :checkout) || workspace[:path] || workspace["path"] || ""
      scripts_root = scripts_root(checkout)
      env_sh = Path.join(staging, "env.sh")
      local_bin = Path.join(home_dir(), ".local/bin")

      path =
        case System.get_env("PATH") do
          p when is_binary(p) and p != "" -> "#{local_bin}:#{Shims.path_with_shims(p)}"
          _ -> "#{local_bin}:/usr/bin:/bin"
        end

      vars =
        %{
          "DEV_IDE_API_TOKEN" => token,
          "DEVIDE_WORKSPACE_ID" => workspace_id,
          "DEVIDE_WORKSPACE_NAME" => workspace_name,
          "DEVIDE_TERMINAL_MCP_URL" => MCPUrls.terminal_url(workspace_id, opts),
          "DEVIDE_PREVIEW_MCP_URL" => MCPUrls.preview_url(workspace_id, opts),
          "DEVIDE_CHECKOUT" => checkout,
          "DEVIDE_AGENT_MCP_HOME" => staging,
          "DEVIDE_SCRIPTS" => scripts_root,
          "DEVIDE_AGENT_ENV_FILE" => env_sh,
          "PATH" => path
        }
        |> maybe_put_tmux_session(opts)
        |> maybe_put_tidewave(workspace, opts)

      {:ok, vars}
    end
  end

  @doc """
  Materialize MCP client configs and push workspace env into a tmux session.
  """
  @spec ensure_for_session(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def ensure_for_session(tmux_session, workspace, opts \\ [])
      when is_binary(tmux_session) and is_map(workspace) do
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
  """
  @spec launch_command(String.t(), map(), keyword()) :: String.t()
  def launch_command(runtime_id, _workspace, _opts \\ [])
      when is_binary(runtime_id) do
    String.trim(runtime_id)
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

  defp home_dir do
    System.get_env("HOME") || "/home/devbox"
  end

  defp api_token do
    case Application.get_env(:dev_ide, :api_token) || non_empty_env("DEV_IDE_API_TOKEN") do
      nil -> {:error, :api_token_missing}
      token -> {:ok, token}
    end
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
