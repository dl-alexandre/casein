defmodule Casein.Terminals.TmuxScope do
  @moduledoc """
  Workspace boundary checks for tmux session names.

  Casein tmux sessions are named from either the workspace manager id or the
  human-facing workspace name. Any user-supplied tmux target must match one of
  those prefixes before the web/API layer captures or mutates it.
  """

  alias Casein.Terminals.Tmux
  alias Casein.Terminals.TmuxPolicy
  alias Casein.Workspaces.Identity

  @doc "Returns the tmux session prefixes allowed for a workspace struct/id."
  def workspace_session_prefixes(%{id: id, name: name}) do
    prefixes_for_candidates([name, id])
  end

  def workspace_session_prefixes(workspace_id) when is_binary(workspace_id) do
    Identity.prefixes(workspace_id)
  end

  def workspace_session_prefixes(_workspace), do: []

  @doc """
  True when a tmux session name belongs to the workspace namespace.

  Delegates the per-prefix test to `TmuxPolicy.session_in_namespace?/2`, which
  matches the full `<prefix><sid>` shape rather than a bare prefix — see that
  function for why `String.starts_with?/2` is not a safe boundary here.
  """
  def session_in_workspace?(session, workspace)
      when is_binary(session) and session != "" do
    workspace
    |> workspace_session_prefixes()
    |> Enum.any?(&TmuxPolicy.session_in_namespace?(session, &1))
  end

  def session_in_workspace?(_session, _workspace), do: false

  @doc """
  True when two session names refer to the same workspace session under
  different allowed prefixes (workspace id vs workspace name).

  `casein_alpha_u-dev` and `casein_ws-1_u-dev` are equivalent for workspace
  `{id: "ws-1", name: "alpha"}`. Different sids are never equivalent.
  """
  @spec equivalent_session?(term(), term(), term()) :: boolean()
  def equivalent_session?(left, right, workspace)
      when is_binary(left) and is_binary(right) do
    left == right or
      match?(
        {sid, sid} when is_binary(sid),
        {session_sid(left, workspace), session_sid(right, workspace)}
      )
  end

  def equivalent_session?(_left, _right, _workspace), do: false

  defp session_sid(session, workspace) do
    workspace
    |> workspace_session_prefixes()
    |> Enum.find_value(fn prefix ->
      if TmuxPolicy.session_in_namespace?(session, prefix) do
        String.replace_prefix(session, prefix, "")
      end
    end)
  end

  defp prefixes_for_candidates(candidates) do
    candidates
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&Tmux.workspace_session_prefix/1)
    |> Enum.uniq()
  end
end
