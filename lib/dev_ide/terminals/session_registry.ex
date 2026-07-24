defmodule Casein.Terminals.SessionRegistry do
  @moduledoc """
  Registry for discovering attachable terminal sessions.

  Sessions are workspace shell sessions backed by tmux/Ghostty PTYs. This
  module provides the discovery mechanism used by `Casein.Terminals`.
  """

  alias Casein.Terminals.Session.Info

  @type session_kind :: :shell

  @type session :: Info.t()

  @doc """
  Returns all currently attachable terminal sessions for the given workspace.

  Most-recently-started first feels natural for operators.
  """
  @spec list_attachable(String.t()) :: [session()]
  def list_attachable(workspace_id) when is_binary(workspace_id) do
    workspace_id
    |> list_workspace_shells()
    |> Enum.sort_by(&sort_key/1, {:desc, DateTime})
  end

  # --- Workspace Shell Sessions (Terminals.Session path) ---

  defp list_workspace_shells(workspace_id) do
    Registry.select(Casein.Terminals.Registry, [
      {
        {{:"$1", :"$2"}, :_, :_},
        [{:==, :"$1", workspace_id}],
        [{{:"$1", :"$2"}}]
      }
    ])
    |> Enum.map(fn {ws_id, sid} ->
      Info.new_shell(ws_id, sid)
    end)
  end

  defp sort_key(%{metadata: %{started_at: %DateTime{} = dt}}), do: dt
  defp sort_key(_), do: DateTime.utc_now()

  @doc """
  Resolves a session identifier (sid) into attachment information.

  Used by TerminalChannel during join.
  """
  @spec resolve(String.t()) :: {:ok, Info.t()} | :error
  def resolve(sid) when is_binary(sid) do
    {:ok, Info.new_shell(nil, sid)}
  end

  def resolve(_), do: :error
end
