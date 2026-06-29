defmodule DevIDE.Terminals.TmuxScope do
  @moduledoc """
  Workspace boundary checks for tmux session names.

  DevIDE tmux sessions are named from either the workspace manager id or the
  human-facing workspace name. Any user-supplied tmux target must match one of
  those prefixes before the web/API layer captures or mutates it.
  """

  alias DevIDE.Terminals.Tmux
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.State

  @doc "Returns the tmux session prefixes allowed for a workspace struct/id."
  def workspace_session_prefixes(%{id: id, name: name}) do
    prefixes_for_candidates([name, id])
  end

  def workspace_session_prefixes(workspace_id) when is_binary(workspace_id) do
    workspace_id
    |> workspace_candidates()
    |> prefixes_for_candidates()
  end

  def workspace_session_prefixes(_workspace), do: []

  @doc "True when a tmux session name belongs to the workspace namespace."
  def session_in_workspace?(session, workspace)
      when is_binary(session) and session != "" do
    workspace
    |> workspace_session_prefixes()
    |> Enum.any?(&String.starts_with?(session, &1))
  end

  def session_in_workspace?(_session, _workspace), do: false

  defp workspace_candidates(workspace_id) do
    case State.get(workspace_id) do
      {:ok, record} -> [workspace_id, Map.get(record, :name), Map.get(record, :external_id)]
      :error -> [workspace_id | source_workspace_candidates(workspace_id)]
    end
  end

  defp source_workspace_candidates(workspace_id) do
    case Workspaces.get(workspace_id) do
      {:ok, workspace} -> [workspace.name, workspace.id]
      _ -> []
    end
  end

  defp prefixes_for_candidates(candidates) do
    candidates
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&Tmux.workspace_session_prefix/1)
    |> Enum.uniq()
  end
end
