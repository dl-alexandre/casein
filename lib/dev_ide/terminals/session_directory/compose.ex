defmodule DevIDE.Terminals.SessionDirectory.Compose do
  @moduledoc """
  Pure composition rules for the workspace session tab list.

  Transplanted from the web layer, where the merge/dedup/staleness logic
  accumulated several regression fixes. Keeping it pure makes every rule
  unit-testable without tmux or a LiveView.

  The canonical list produced by `compose/2` is viewer-independent: it keeps
  every workspace shell, including other browser tabs' shells. Each consumer
  applies `visible_for/2` with its own default sid to hide its own shell tab
  (it has a dedicated "Shell" button) and sibling browser-tab shells from the
  same session family.
  """

  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIDE.Terminals.Tmux

  @doc """
  Merges scanned tmux sessions with live attachable sessions into the
  canonical tab list, deduplicating by `{kind, attach_id}`. Scanned entries
  win ties because they carry the live tmux session name and activity
  metadata that registry entries may lack.
  """
  @spec compose([SessionInfo.t()], [SessionInfo.t()]) :: [SessionInfo.t()]
  def compose(scanned, attachable) when is_list(scanned) and is_list(attachable) do
    Enum.uniq_by(scanned ++ attachable, &{&1.kind, attach_id(&1)})
  end

  @doc """
  Maps raw `tmux list-sessions` rows to shell `SessionInfo`s for sessions
  belonging to the given workspace (by tmux name prefix).
  """
  @spec scan_tmux_sessions([map() | String.t()], String.t(), String.t()) :: [SessionInfo.t()]
  def scan_tmux_sessions(raw_sessions, workspace_id, workspace_name) do
    prefix = Tmux.session_name(workspace_name, "")

    Enum.flat_map(raw_sessions, &scanned_session_info(&1, prefix, workspace_id))
  end

  @doc """
  Applies the per-viewer filters: hides the viewer's own default shell (the
  bar renders a dedicated Shell button for it) and stale sibling browser-tab
  shells from the same family as the viewer's sid.
  """
  @spec visible_for([SessionInfo.t()], String.t() | nil) :: [SessionInfo.t()]
  def visible_for(tabs, default_sid) when is_list(tabs) do
    tabs
    |> Enum.reject(&default_shell?(&1, default_sid))
    |> Enum.reject(&stale_browser_shell?(&1, default_sid))
  end

  @doc "The id used to attach a session: the sid for shells, the info id otherwise."
  @spec attach_id(SessionInfo.t()) :: String.t()
  def attach_id(%SessionInfo{kind: :shell, sid: sid}), do: sid
  def attach_id(%SessionInfo{id: id}), do: id

  @doc """
  Extracts the browser shell family from a per-tab sid.

  Per-tab sids look like `u-<user>-<tab id>` where the tab id is either an
  8-char hex-ish suffix or a `t`-prefixed 6-char id (see the tab_id connect
  param in `WorkspaceLive.Show.mount/3`). Plain `u-<user>` sids have no
  family — they are deliberate, shared shells and never filtered.

      iex> DevIDE.Terminals.SessionDirectory.Compose.shell_family("u-alice-abcd1234")
      "u-alice"

      iex> DevIDE.Terminals.SessionDirectory.Compose.shell_family("u-alice-tabc123")
      "u-alice"

      iex> DevIDE.Terminals.SessionDirectory.Compose.shell_family("u-alice")
      nil

      iex> DevIDE.Terminals.SessionDirectory.Compose.shell_family("custom-shell")
      nil
  """
  @spec shell_family(String.t() | nil) :: String.t() | nil
  def shell_family(sid) when is_binary(sid) do
    case Regex.run(~r/^(u-.+)-([a-z0-9]{8}|t[a-z0-9]{6})$/, sid) do
      [_, family, _tab_id] -> family
      _ -> nil
    end
  end

  def shell_family(_sid), do: nil

  @doc """
  A change-detection hash over the identity-relevant tab fields. Volatile
  metadata (tmux activity timestamps) is excluded so the directory does not
  broadcast on every poll.
  """
  @spec stable_hash([SessionInfo.t()]) :: non_neg_integer()
  def stable_hash(tabs) do
    tabs
    |> Enum.map(&{&1.kind, attach_id(&1), &1.sid, &1.tmux_session, &1.status})
    |> Enum.sort()
    |> :erlang.phash2()
  end

  defp scanned_session_info(raw, prefix, workspace_id) do
    with session when is_binary(session) <- tmux_session_name(raw),
         true <- String.starts_with?(session, prefix),
         sid when sid != "" <- String.replace_prefix(session, prefix, "") do
      [
        SessionInfo.new_shell(workspace_id, sid, metadata: session_metadata(raw))
        |> Map.put(:tmux_session, session)
      ]
    else
      _ -> []
    end
  end

  defp tmux_session_name(%{session: session}), do: session
  defp tmux_session_name(session) when is_binary(session), do: session
  defp tmux_session_name(_raw), do: nil

  defp session_metadata(%{} = raw) do
    raw
    |> Map.take([:activity, :attached])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp session_metadata(_raw), do: %{}

  defp default_shell?(%SessionInfo{kind: :shell, sid: sid}, default_sid)
       when is_binary(default_sid),
       do: sid == default_sid

  defp default_shell?(_info, _default_sid), do: false

  defp stale_browser_shell?(%SessionInfo{kind: :shell, sid: sid}, default_sid)
       when is_binary(sid) and is_binary(default_sid) do
    case {shell_family(sid), shell_family(default_sid)} do
      {family, family} when is_binary(family) -> sid != default_sid
      _ -> false
    end
  end

  defp stale_browser_shell?(_info, _default_sid), do: false
end
