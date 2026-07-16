defmodule DevIDE.Agents.GrokCapabilityPolicy do
  @moduledoc """
  Computes the exact DevIDE MCP grant for a managed Grok leader.

  A token's issued tool map is a ceiling. Every request intersects that ceiling
  with the workspace's current mode, DB-isolation state, and time-boxed agent
  write unlock, so revoking an unlock takes effect without waiting for expiry.
  """

  alias DevIDE.Agents.{ArtifactTools, PreviewTools, TerminalTools}
  alias DevIDE.Policy
  alias DevIDE.Policy.Decision
  alias DevIDE.Workspaces
  alias McpCtl.Tool

  @policy_version 1
  @reporting_tools ~w(
    annotation_propose
    terminal_report_agent_state
    terminal_report_worktree
    terminal_set_agent_label
  )
  @never_grant_tools ~w(terminal_send_command terminal_send_keys)

  @type tool_map :: %{String.t() => [String.t()]}

  @doc "Current policy snapshot used when a Grok capability is issued."
  @spec snapshot(String.t()) :: %{
          mode: String.t(),
          mode_source: String.t(),
          policy_version: pos_integer(),
          write_enabled: boolean(),
          allowed_tools: tool_map()
        }
  def snapshot(workspace_id) when is_binary(workspace_id) do
    {mode, source} = Workspaces.mode_for(workspace_id)
    write_enabled = write_enabled?(workspace_id)

    %{
      mode: Atom.to_string(mode),
      mode_source: Atom.to_string(source),
      policy_version: @policy_version,
      write_enabled: write_enabled,
      allowed_tools: allowed_tools(write_enabled)
    }
  end

  @doc "Intersect frozen token grants with current workspace policy."
  @spec effective_tools(map()) :: {:ok, tool_map(), map()} | {:error, atom()}
  def effective_tools(%{workspace_id: workspace_id, allowed_tools: issued})
      when is_binary(workspace_id) and is_map(issued) do
    current = snapshot(workspace_id)

    effective =
      Map.new(current.allowed_tools, fn {surface, current_names} ->
        issued_names = Map.get(issued, surface, [])
        {surface, Enum.filter(current_names, &(&1 in issued_names))}
      end)

    {:ok, effective, current}
  end

  def effective_tools(_claims), do: {:error, :invalid_capability_claims}

  @doc "Every direct DevIDE MCP tool must carry explicit mutation metadata."
  @spec classified?() :: boolean()
  def classified? do
    definitions()
    |> Enum.all?(fn {_surface, tool} ->
      case Tool.public_metadata(tool) do
        %{"mutation" => mutation?} when is_boolean(mutation?) -> true
        _ -> false
      end
    end)
  end

  @doc "Validate a DevIDE tmux session name against a workspace id/name."
  @spec valid_tmux_session?(String.t(), String.t()) :: boolean()
  def valid_tmux_session?(workspace_id, session)
      when is_binary(workspace_id) and is_binary(session) and session != "" do
    workspace_keys =
      case Workspaces.get(workspace_id) do
        {:ok, workspace} -> [workspace_id, workspace.name]
        _ -> [workspace_id]
      end

    workspace_keys
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&DevIDE.Terminals.tmux_workspace_session_prefix/1)
    |> Enum.uniq()
    |> Enum.any?(&String.starts_with?(session, &1))
  end

  def valid_tmux_session?(_workspace_id, _session), do: false

  defp allowed_tools(write_enabled) do
    definitions()
    |> Enum.group_by(fn {surface, _tool} -> surface end, fn {_surface, tool} -> tool end)
    |> Map.new(fn {surface, tools} ->
      names =
        tools
        |> Enum.filter(&allowed_tool?(&1, write_enabled))
        |> Enum.map(& &1.name)
        |> Enum.sort()

      {surface, names}
    end)
  end

  defp allowed_tool?(tool, write_enabled) do
    if tool.name in @never_grant_tools do
      false
    else
      case Tool.public_metadata(tool) do
        %{"mutation" => false} -> true
        %{"mutation" => true} -> write_enabled or tool.name in @reporting_tools
        _missing_or_invalid -> false
      end
    end
  end

  defp definitions do
    for {surface, tools} <- [
          {"terminal", TerminalTools.definitions()},
          {"preview", PreviewTools.definitions()},
          {"artifact", ArtifactTools.definitions()}
        ],
        tool <- tools do
      {surface, tool}
    end
  end

  defp write_enabled?(workspace_id) do
    ctx = %{workspace_id: workspace_id, db_isolation: db_isolation(workspace_id)}
    match?(%Decision{verdict: :allow}, Policy.can_enable_agent_write?(ctx))
  end

  defp db_isolation(workspace_id) do
    case Workspaces.get_record(workspace_id) do
      {:ok, %{db_isolation: "shared_stage"}} -> :shared_stage
      {:ok, %{db_isolation: "unsafe"}} -> :unsafe
      {:ok, %{db_isolation: isolation}} when is_binary(isolation) -> :isolated
      _ -> nil
    end
  end
end
