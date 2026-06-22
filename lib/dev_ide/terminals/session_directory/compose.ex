defmodule DevIDE.Terminals.SessionDirectory.Compose do
  @moduledoc """
  Pure composition rules for the workspace session tab list.

  Transplanted from the web layer, where the merge/dedup/staleness logic
  accumulated several regression fixes. Keeping it pure makes every rule
  unit-testable without tmux or a LiveView.

  The canonical list produced by `compose/2` is viewer-independent: it keeps
  every workspace shell tmux knows about. Each consumer applies `visible_for/2`
  with its own default sid to hide its own shell tab, which has a dedicated
  Shell button.
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
  @spec scan_tmux_sessions([map() | String.t()], String.t(), String.t() | [String.t()]) :: [
          SessionInfo.t()
        ]
  def scan_tmux_sessions(raw_sessions, workspace_id, workspace_names) do
    prefixes = workspace_prefixes(workspace_names)

    Enum.flat_map(raw_sessions, &scanned_session_info(&1, prefixes, workspace_id))
  end

  @doc """
  Applies the per-viewer filters: hides the viewer's own default shell because
  the bar renders a dedicated Shell button for it.

  Used only by the deep-link list (which renders the shell separately). The
  interactive picker keeps the default shell in the list via `with_default_shell/4`.
  """
  @spec visible_for([SessionInfo.t()], String.t() | nil) :: [SessionInfo.t()]
  def visible_for(tabs, default_sid) when is_list(tabs) do
    Enum.reject(tabs, &default_shell?(&1, default_sid))
  end

  @doc """
  Guarantees the viewer's landing session is present so the session picker always
  shows a "home" row, even before the live scan has discovered it (just-mounted,
  empty scan). If a scanned shell already carries `default_sid`, the list is
  returned unchanged; otherwise a minimal placeholder shell is prepended.
  """
  @spec with_default_shell([SessionInfo.t()], String.t() | nil, String.t(), String.t()) ::
          [SessionInfo.t()]
  def with_default_shell(infos, default_sid, workspace_id, workspace_name)
      when is_list(infos) and is_binary(default_sid) and default_sid != "" do
    if Enum.any?(infos, &default_shell?(&1, default_sid)) do
      infos
    else
      placeholder =
        workspace_id
        |> SessionInfo.new_shell(default_sid)
        |> Map.put(:tmux_session, Tmux.session_name(workspace_name, default_sid))

      [placeholder | infos]
    end
  end

  def with_default_shell(infos, _default_sid, _workspace_id, _workspace_name), do: infos

  @doc "The id used to attach a session: the sid for shells, the info id otherwise."
  @spec attach_id(SessionInfo.t()) :: String.t()
  def attach_id(%SessionInfo{kind: :shell, sid: sid}), do: sid
  def attach_id(%SessionInfo{id: id}), do: id

  @doc """
  Extracts the browser shell family from a per-tab sid.

  Per-tab sids look like `u-<user>-<tab id>` where the tab id is either a
  7-8 char base36-ish suffix or a `t`-prefixed 6-char id (see the tab_id connect
  param in `WorkspaceLive.Show.mount/3`). Plain `u-<user>` sids have no
  family — they are deliberate, shared shells and never filtered.

      iex> DevIDE.Terminals.SessionDirectory.Compose.shell_family("u-alice-abcd1234")
      "u-alice"

      iex> DevIDE.Terminals.SessionDirectory.Compose.shell_family("u-alice-abc1234")
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
    case Regex.run(~r/^(u-.+)-([a-z0-9]{7,8}|t[a-z0-9]{6})$/, sid) do
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
    |> Enum.map(
      &{&1.kind, attach_id(&1), &1.sid, &1.tmux_session, &1.status, session_context(&1)}
    )
    |> Enum.sort()
    |> :erlang.phash2()
  end

  defp session_context(%SessionInfo{metadata: metadata}) when is_map(metadata) do
    Enum.map(
      [
        :cwd,
        :git_toplevel,
        :git_common_dir,
        :git_branch,
        :git_head_sha,
        :git_worktree?,
        :git_detached?,
        :agent,
        :windows
      ],
      &metadata_value(metadata, &1)
    )
  end

  defp session_context(_), do: nil

  defp metadata_value(metadata, key) when is_atom(key) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end

  defp workspace_prefixes(workspace_names) when is_list(workspace_names) do
    workspace_names
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&Tmux.session_name(&1, ""))
    |> Enum.uniq()
  end

  defp workspace_prefixes(workspace_name), do: workspace_prefixes([workspace_name])

  defp scanned_session_info(raw, prefixes, workspace_id) do
    with session when is_binary(session) <- tmux_session_name(raw),
         prefix when is_binary(prefix) <- Enum.find(prefixes, &String.starts_with?(session, &1)),
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
    |> Map.take([:activity, :attached, :session_alias])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp session_metadata(_raw), do: %{}

  defp default_shell?(%SessionInfo{kind: :shell, sid: sid}, default_sid)
       when is_binary(default_sid),
       do: sid == default_sid

  defp default_shell?(_info, _default_sid), do: false
end
