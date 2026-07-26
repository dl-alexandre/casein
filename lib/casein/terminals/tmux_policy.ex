defmodule Casein.Terminals.TmuxPolicy do
  @moduledoc """
  Casein-specific tmux session naming and sanitization rules.
  """

  @session_prefix "casein"

  @doc """
  Build a managed tmux session name for a workspace and session id.
  """
  @spec session_name(String.t(), String.t()) :: String.t()
  def session_name(workspace_name, sid) do
    "#{@session_prefix}_#{sanitize(workspace_name)}_#{sanitize(sid)}"
  end

  @doc """
  Prefix shared by every Casein tmux session for a workspace name or id.

  Used to scope agent terminal MCP tools to one workspace.
  """
  @spec workspace_session_prefix(String.t()) :: String.t()
  def workspace_session_prefix(workspace_name) do
    session_name(workspace_name, "")
  end

  @doc """
  Sanitize user-provided segments for tmux session names.
  """
  @spec sanitize(term()) :: String.t()
  def sanitize(s) do
    s
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_\-]/, "_")
    |> String.slice(0, 64)
  end
end
