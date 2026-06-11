defmodule DevIdeWeb.WorkspaceLive.Show.TerminalState do
  # Terminal/tmux socket-state helpers extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  @moduledoc false

  use DevIdeWeb, :verified_routes

  import Phoenix.Component
  import Phoenix.LiveView
  import DevIdeWeb.WorkspaceLive.Show.TerminalChrome, only: [session_attach_id: 1]

  alias DevIDE.Terminals
  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxTopology
  alias DevIdeWeb.WorkspaceLive.Show
  alias DevIdeWeb.WorkspaceLive.Show.SessionBarVM

  def tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, Tmux)
  end

  def refresh_tmux_topology(socket) do
    topology = TmuxTopology.snapshot(socket.assigns.tmux_session, tmux: tmux_adapter())

    assign_tmux_topology(socket, topology)
  end

  def assign_tmux_topology(socket, topology) do
    socket
    |> assign(:tmux_windows, topology.windows)
    |> assign(:tmux_panes, topology.panes)
    |> assign(:tmux_active_window_id, topology.active_window_id)
    |> assign(:tmux_active_pane_id, topology.active_pane_id)
    |> assign(:tmux_topology_version, topology.version)
  end

  def subscribe_tmux_topology(socket) do
    if connected?(socket) do
      session = socket.assigns.tmux_session

      _ =
        TmuxTopology.ensure_started(session,
          workspace_id: socket.assigns.workspace.id
        )

      _ = TmuxTopology.subscribe(session)
    end

    socket
  end

  def unsubscribe_tmux_topology(socket, nil), do: socket

  def unsubscribe_tmux_topology(socket, session) when is_binary(session) do
    if connected?(socket) do
      Phoenix.PubSub.unsubscribe(DevIde.PubSub, TmuxTopology.topic(session))
    end

    socket
  end

  def switch_active_session(socket, sid, tmux_session_hint \\ nil) do
    case resolve_active_session(socket, sid, tmux_session_hint) do
      {:ok, info, tmux_session} ->
        old_session = socket.assigns.tmux_session
        mode = session_switch_terminal_mode(socket, info)

        socket =
          socket
          |> unsubscribe_tmux_topology(old_session)
          |> reset_panes_for_session_switch(info, sid, tmux_session)
          |> Show.audit_terminal_mode_transition(socket.assigns[:terminal_mode], mode)
          |> assign_active_terminal_session(info, sid, tmux_session, mode)
          |> assign(:tmux_rename_window_id, nil)
          |> subscribe_tmux_topology()
          |> refresh_tmux_topology()

        maybe_start_switched_raw_session(socket, mode)

      {:error, :session_ended} ->
        socket
        |> put_flash(:error, "Terminal session ended. Refreshed sessions.")
        |> assign_session_tabs()

      :error ->
        put_flash(socket, :error, "Could not switch terminal session.")
    end
  end

  def assign_active_terminal_session(socket, %SessionInfo{} = info, sid, tmux_session, mode) do
    socket
    |> assign(:terminal_sid, sid)
    |> assign(:terminal_workspace_capability, Show.terminal_workspace_capability(socket, sid))
    |> assign(:terminal_mode, mode)
    |> assign(:tmux_session, tmux_session)
    |> assign(:active_session_kind, info.kind)
    |> assign(:tmux_mutations_enabled?, tmux_mutations_enabled?(info.kind))
  end

  def session_switch_terminal_mode(socket, %SessionInfo{} = info) do
    cond do
      Terminals.governed_by_default?(info) ->
        :governed

      info.kind == :shell and
          Show.raw_terminal_allowed?(socket.assigns[:workspace_mode], socket.assigns[:host_id]) ->
        :raw

      true ->
        :governed
    end
  end

  def reset_panes_for_session_switch(socket, %SessionInfo{kind: :shell}, sid, tmux_session) do
    socket
    |> Show.cleanup_ghostty_resources_if_leaving()
    |> Show.put_pane_layout({:pane, "pane-1"})
    |> assign(:pane_data, primary_pane_data(sid, tmux_session))
    |> assign(:focused_pane_id, "pane-1")
    |> assign(:zoomed_pane_id, nil)
  end

  def reset_panes_for_session_switch(socket, _info, _sid, _tmux_session) do
    Show.cleanup_ghostty_resources_if_leaving(socket)
  end

  def maybe_start_switched_raw_session(socket, mode) when mode in [:raw, :raw_ghostty] do
    socket
    |> Show.start_ghostty_terminal()
    |> push_event("request_saved_layout", %{"workspace_id" => socket.assigns.workspace.id})
  end

  def maybe_start_switched_raw_session(socket, _mode), do: socket

  def primary_pane_data(sid, tmux_session) do
    %{
      "pane-1" => %{
        ghostty_term: nil,
        ghostty_pty: nil,
        worker: nil,
        backend: nil,
        session_sid: sid,
        tmux_session: tmux_session,
        cols: 120,
        rows: 40,
        error: nil,
        auto_retry_count: 0
      }
    }
  end

  def resolve_active_session(socket, sid, tmux_session_hint) do
    ws = socket.assigns.workspace
    workspace_name = ws.name || ws.id

    case Terminals.resolve(sid) do
      {:ok, %SessionInfo{} = info} ->
        tmux_session =
          case tmux_session_for_info(info, workspace_name) do
            nil when is_binary(tmux_session_hint) and tmux_session_hint != "" -> tmux_session_hint
            session when is_binary(session) -> session
            _ -> nil
          end

        cond do
          not is_binary(tmux_session) ->
            :error

          active_session_available?(socket, info, sid, tmux_session) ->
            {:ok, info, tmux_session}

          true ->
            {:error, :session_ended}
        end

      :error ->
        :error
    end
  end

  def tmux_session_for_info(%SessionInfo{kind: :execution, tmux_session: tmux}, _workspace_name)
      when is_binary(tmux),
      do: tmux

  def tmux_session_for_info(%SessionInfo{kind: :shell, sid: sid}, workspace_name)
      when is_binary(sid),
      do: Tmux.session_name(workspace_name, sid)

  def tmux_session_for_info(_info, _workspace_name), do: nil

  def active_session_available?(socket, %SessionInfo{kind: :shell}, sid, tmux_session) do
    sid == socket.assigns[:default_terminal_sid] or tmux_session_alive?(tmux_session)
  end

  def active_session_available?(_socket, %SessionInfo{kind: :execution}, _sid, tmux_session) do
    tmux_session_alive?(tmux_session)
  end

  def active_session_available?(_socket, _info, _sid, tmux_session) do
    tmux_session_alive?(tmux_session)
  end

  def tmux_session_alive?(session) when is_binary(session) do
    adapter = tmux_adapter()

    if function_exported?(adapter, :session_alive?, 1) do
      adapter.session_alive?(session)
    else
      true
    end
  rescue
    _ -> false
  end

  def tmux_session_alive?(_session), do: false

  def tmux_mutations_enabled?(:shell), do: true
  def tmux_mutations_enabled?(_kind), do: false

  def tmux_mutations_allowed?(socket), do: socket.assigns[:tmux_mutations_enabled?] == true

  def deny_tmux_mutation(socket) do
    {:noreply, put_flash(socket, :error, "Tmux layout changes are not allowed for this session.")}
  end

  def ensure_primary_tmux_session(socket) do
    case tmux_adapter().ensure_session(socket.assigns.tmux_session, Show.workspace_cwd(socket)) do
      :ok -> socket
      {:error, _reason} -> socket
    end
  end

  def assign_session_tabs(socket) do
    tabs =
      socket.assigns.workspace
      |> terminal_session_tabs(socket.assigns[:default_terminal_sid])
      |> SessionBarVM.session_tabs()

    assign(socket, :session_tabs, tabs)
  end

  def rename_tmux_window(socket, window_id, name) do
    name = String.trim(to_string(name || ""))

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Window name cannot be blank.")}

      true ->
        case tmux_adapter().rename_window(socket.assigns.tmux_session, window_id, name) do
          :ok ->
            {:noreply,
             socket
             |> assign(:tmux_rename_window_id, nil)
             |> refresh_tmux_topology()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not rename tmux window: #{inspect(reason)}")}
        end
    end
  end

  def parse_resize_amount(nil), do: {:ok, Tmux.resize_amount_default()}

  def parse_resize_amount(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> validate_resize_amount(integer)
      _ -> {:error, :invalid_amount}
    end
  end

  def parse_resize_amount(value) when is_integer(value) and value > 0 do
    validate_resize_amount(value)
  end

  def parse_resize_amount(_), do: {:error, :invalid_amount}

  defp validate_resize_amount(value) do
    if value <= Tmux.resize_amount_max() do
      {:ok, value}
    else
      {:error, :invalid_amount}
    end
  end

  def workspace_window_path(socket, window_id) do
    base = ~p"/workspaces/#{socket.assigns.workspace.id}"

    query =
      %{
        "host" => socket.assigns.host_id,
        "session" => selected_terminal_session_param(socket),
        "window" => window_id
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    if query == "", do: base, else: base <> "?" <> query
  end

  def patch_current_session(socket) do
    push_patch(socket, to: workspace_window_path(socket, socket.assigns[:tmux_active_window_id]))
  end

  defp selected_terminal_session_param(socket) do
    sid = socket.assigns[:terminal_sid]
    default_sid = socket.assigns[:default_terminal_sid]

    if is_binary(sid) and sid != "" and sid != default_sid, do: sid
  end

  def terminal_session_tabs(workspace, default_sid) do
    attachable =
      workspace.id
      |> Terminals.list_attachable()
      |> Enum.reject(&stale_browser_shell_session?(&1, default_sid))

    tmux_sessions = tmux_workspace_sessions(workspace, default_sid)

    (tmux_sessions ++ attachable)
    |> dedupe_session_tabs()
    |> session_tabs_for(default_sid)
  end

  defp tmux_workspace_sessions(workspace, default_sid) do
    workspace_name = workspace.name || workspace.id
    prefix = Tmux.session_name(workspace_name, "")

    tmux_list_sessions()
    |> Enum.flat_map(&tmux_workspace_session_info(&1, prefix, workspace.id, default_sid))
  end

  defp tmux_list_sessions do
    adapter = tmux_adapter()

    if function_exported?(adapter, :list_sessions, 0) do
      adapter.list_sessions()
    else
      []
    end
  end

  defp tmux_workspace_session_info(raw, prefix, workspace_id, default_sid) do
    with session when is_binary(session) <- tmux_session_name(raw),
         true <- String.starts_with?(session, prefix),
         sid when sid != "" <- String.replace_prefix(session, prefix, ""),
         false <- stale_browser_shell_sid?(sid, default_sid) do
      [
        SessionInfo.new_shell(workspace_id, sid, metadata: tmux_session_metadata(raw))
        |> Map.put(:tmux_session, session)
      ]
    else
      _ -> []
    end
  end

  defp tmux_session_name(%{session: session}), do: session
  defp tmux_session_name(session) when is_binary(session), do: session
  defp tmux_session_name(_raw), do: nil

  defp tmux_session_metadata(%{} = raw) do
    raw
    |> Map.take([:activity, :attached])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp tmux_session_metadata(_raw), do: %{}

  defp dedupe_session_tabs(sessions) do
    Enum.uniq_by(sessions, &{&1.kind, session_attach_id(&1)})
  end

  defp session_tabs_for(sessions, default_sid) do
    Enum.reject(sessions, &default_shell_session?(&1, default_sid))
  end

  defp stale_browser_shell_session?(%SessionInfo{kind: :shell, sid: sid}, default_sid),
    do: stale_browser_shell_sid?(sid, default_sid)

  defp stale_browser_shell_session?(_session, _default_sid), do: false

  defp stale_browser_shell_sid?(sid, default_sid)
       when is_binary(sid) and is_binary(default_sid) do
    case {browser_shell_family(sid), browser_shell_family(default_sid)} do
      {family, family} when is_binary(family) -> sid != default_sid
      _ -> false
    end
  end

  defp stale_browser_shell_sid?(_sid, _default_sid), do: false

  defp browser_shell_family(sid) do
    case Regex.run(~r/^(u-.+)-([a-z0-9]{8}|t[a-z0-9]{6})$/, sid) do
      [_, family, _tab_id] -> family
      _ -> nil
    end
  end

  defp default_shell_session?(%SessionInfo{kind: :shell, sid: sid}, default_sid)
       when is_binary(default_sid),
       do: sid == default_sid

  defp default_shell_session?(_session, _default_sid), do: false
end
