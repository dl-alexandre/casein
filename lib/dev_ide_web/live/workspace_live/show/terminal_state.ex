defmodule DevIdeWeb.WorkspaceLive.Show.TerminalState do
  # Terminal/tmux socket-state helpers extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  @moduledoc false

  use DevIdeWeb, :verified_routes

  import Phoenix.Component
  import Phoenix.LiveView

  alias DevIDE.Terminals
  alias DevIDE.Terminals.ModePolicy
  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIDE.Terminals.SessionDirectory
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxTopology
  alias DevIdeWeb.WorkspaceLive.Show
  alias DevIdeWeb.WorkspaceLive.Show.SessionBarVM
  alias DevIdeWeb.WorkspaceLive.Show.TerminalChrome

  def tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, Tmux)
  end

  @doc """
  Re-applies topology after a tmux mutation.

  Connected sockets refresh through the session's shared watcher: the tmux
  read runs in the watcher process (one merged subprocess) and its change
  broadcast updates every other viewer, instead of each event forking a
  private subprocess pair on the LiveView. Disconnected renders keep the
  direct snapshot — no watcher exists for them.
  """
  def refresh_tmux_topology(socket) do
    session = socket.assigns.tmux_session

    topology =
      if connected?(socket) do
        TmuxTopology.refresh_now(session, workspace_id: socket.assigns.workspace.id)
      else
        TmuxTopology.snapshot(session, tmux: tmux_adapter())
      end

    assign_tmux_topology(socket, topology)
  end

  def assign_tmux_topology(socket, topology) do
    prev_window = socket.assigns[:tmux_active_window_id]
    prev_active_pane = socket.assigns[:tmux_active_pane_id]
    preview_panes = socket.assigns[:preview_panes] || %{}

    active_window_panes = TerminalChrome.active_tmux_window_panes(topology.windows)

    socket
    |> assign(:tmux_windows, topology.windows)
    |> assign(:tmux_panes, topology.panes)
    |> assign_header_session_labels(topology)
    |> assign(:tmux_active_window_id, topology.active_window_id)
    |> assign(:tmux_active_pane_id, topology.active_pane_id)
    |> assign(
      :terminal_surface_pane_id,
      TerminalChrome.terminal_surface_pane_id(
        active_window_panes,
        preview_panes,
        topology.active_pane_id,
        socket.assigns[:terminal_surface_pane_id]
      )
    )
    |> sync_ui_highlight_pane_id(topology.active_pane_id, prev_active_pane, preview_panes)
    |> then(fn s ->
      if prev_window != topology.active_window_id do
        assign(s, :window_zoomed?, false)
      else
        s
      end
    end)
    |> assign_page_title()
    |> assign(:tmux_topology_version, topology.version)
    # Structure-only version for DOM consumers (window dropdown data-version):
    # stable across activity-only polls. Falls back to the full version for
    # topology maps that predate the field (hydration payloads, test fixtures).
    |> assign(
      :tmux_topology_structure_version,
      Map.get(topology, :structure_version, topology.version)
    )
    # Direct snapshot reads carry no generation; keep the stored one then.
    |> assign(
      :tmux_topology_generation,
      Map.get(topology, :generation, socket.assigns[:tmux_topology_generation])
    )
    |> restore_operator_tmux_focus(preview_panes)
    |> assign_tmux_window_tabs()
  end

  @doc """
  Keeps tmux focused on the sticky operator terminal pane.

  Ghostty reads the tmux-active pane, so preview splits must not leave a
  preview holder as the live PTY target.
  """
  def restore_operator_tmux_focus(socket, preview_panes \\ nil) do
    preview_panes = preview_panes || socket.assigns[:preview_panes] || %{}
    surface = socket.assigns[:terminal_surface_pane_id]
    active = socket.assigns[:tmux_active_pane_id]

    if connected?(socket) and is_binary(surface) and surface != "" and surface != active and
         Map.has_key?(preview_panes, active) do
      case tmux_adapter().select_pane(socket.assigns.tmux_session, surface) do
        :ok -> socket
        {:error, _reason} -> socket
      end
    else
      socket
    end
  end

  defp assign_tmux_window_tabs(socket) do
    assign(
      socket,
      :tmux_window_tabs,
      SessionBarVM.window_tabs(
        socket.assigns.tmux_windows,
        socket.assigns[:ui_highlight_pane_id]
      )
    )
  end

  defp sync_ui_highlight_pane_id(socket, active_pane_id, prev_active_pane, preview_panes) do
    current = socket.assigns[:ui_highlight_pane_id]

    highlight =
      cond do
        is_nil(current) ->
          active_pane_id

        Map.has_key?(preview_panes, active_pane_id) ->
          active_pane_id

        Map.has_key?(preview_panes, prev_active_pane) and active_pane_id != prev_active_pane ->
          current

        current == prev_active_pane and active_pane_id != prev_active_pane ->
          active_pane_id

        true ->
          current
      end

    assign(socket, :ui_highlight_pane_id, highlight)
  end

  defp assign_page_title(socket) do
    ws_name = socket.assigns[:workspace] && socket.assigns.workspace.name

    terminal_sid = socket.assigns[:terminal_sid]

    session_name =
      (socket.assigns[:session_tabs] || [])
      |> Enum.find(&(&1.id == terminal_sid))
      |> case do
        nil -> nil
        tab -> tab.label
      end

    window_name =
      (socket.assigns[:tmux_windows] || [])
      |> Enum.find(&(&1.id == socket.assigns[:tmux_active_window_id]))
      |> case do
        nil -> nil
        w -> w.name
      end

    terminal_part =
      case {session_name, window_name} do
        {nil, nil} -> nil
        {nil, w} -> w
        {s, nil} -> s
        {s, w} -> "#{s} / #{w}"
      end

    title =
      [ws_name, terminal_part]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    assign(socket, :page_title, if(title == "", do: "DevIde", else: title))
  end

  @doc """
  Derives the header session-dropdown label/detail and active-window pane
  count as their own assigns.

  The raw `@tmux_panes` list carries activity timestamps and is therefore
  re-assigned (never term-equal) on every watcher broadcast; reading it from
  header attrs re-rendered the header every 300ms while any pane produced
  output. These derived values almost never change, so `assign/3`'s
  equality skip suppresses the no-op diffs.
  """
  def assign_header_session_labels(socket, topology) do
    panes = topology.panes
    default_sid = socket.assigns[:default_terminal_sid]
    active_sid = socket.assigns[:terminal_sid]

    socket
    |> assign(
      :shell_button_label,
      TerminalChrome.shell_button_label(
        default_sid,
        active_sid,
        panes,
        socket.assigns[:host_path]
      )
    )
    |> assign(
      :shell_button_detail,
      TerminalChrome.shell_button_detail(default_sid, active_sid, panes)
    )
    |> assign(
      :active_window_pane_count,
      Enum.count(panes, &(&1.window_id == topology.active_window_id))
    )
  end

  def focus_active_terminal(socket, extra \\ %{}) do
    tmux_pane_id =
      socket.assigns[:terminal_surface_pane_id] || socket.assigns[:tmux_active_pane_id]

    payload =
      %{
        "workspace_id" => socket.assigns[:workspace] && socket.assigns.workspace.id,
        "pane_id" => socket.assigns[:focused_pane_id],
        "tmux_pane_id" => tmux_pane_id,
        "terminal_mode" => terminal_mode_name(socket.assigns[:terminal_mode])
      }
      |> Map.merge(extra)
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    push_event(socket, "terminal:focus_active", payload)
  end

  defp terminal_mode_name(nil), do: nil
  defp terminal_mode_name(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp terminal_mode_name(mode), do: to_string(mode)

  def subscribe_tmux_topology(socket) do
    if connected?(socket) do
      {:ok, %{generation: generation}} =
        TmuxTopology.switch_subscription(nil, socket.assigns.tmux_session,
          read: :get,
          workspace_id: socket.assigns.workspace.id
        )

      assign(socket, :tmux_topology_generation, generation)
    else
      socket
    end
  end

  @doc """
  Atomically moves the LiveView's topology subscription to the (already
  assigned) current tmux session and applies a fresh topology, replacing the
  old unsubscribe → subscribe → refresh sequence that could interleave with
  stale broadcasts during rapid session switches.
  """
  def switch_topology_subscription(socket, old_session) do
    if connected?(socket) do
      {:ok, %{generation: generation, topology: topology}} =
        TmuxTopology.switch_subscription(old_session, socket.assigns.tmux_session,
          workspace_id: socket.assigns.workspace.id
        )

      socket
      |> assign(:tmux_topology_generation, generation)
      |> assign_tmux_topology(topology)
    else
      refresh_tmux_topology(socket)
    end
  end

  def switch_active_session(socket, sid, tmux_session_hint \\ nil) do
    case resolve_active_session(socket, sid, tmux_session_hint) do
      {:ok, info, tmux_session} ->
        old_session = socket.assigns.tmux_session
        mode = session_switch_terminal_mode(socket, info)

        socket =
          socket
          |> reset_panes_for_session_switch(info, sid, tmux_session)
          |> Show.audit_terminal_mode_transition(socket.assigns[:terminal_mode], mode)
          |> assign_active_terminal_session(info, sid, tmux_session, mode)
          |> assign(:tmux_rename_window_id, nil)
          |> switch_topology_subscription(old_session)

        maybe_start_switched_raw_session(socket, mode)

      {:error, :session_ended} ->
        socket
        |> put_flash(:error, "Terminal session ended. Refreshed sessions.")
        |> refresh_session_tabs()

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
    ModePolicy.session_switch_mode(
      info,
      socket.assigns[:workspace_mode],
      socket.assigns[:host_id]
    )
  end

  def reset_panes_for_session_switch(socket, %SessionInfo{kind: :shell}, sid, tmux_session) do
    socket
    |> Show.cleanup_ghostty_resources_if_leaving()
    |> assign(:pane_data, primary_pane_data(sid, tmux_session))
    |> assign(:focused_pane_id, "pane-1")
  end

  def reset_panes_for_session_switch(socket, _info, _sid, _tmux_session) do
    Show.cleanup_ghostty_resources_if_leaving(socket)
  end

  def maybe_start_switched_raw_session(socket, mode) when mode in [:raw, :raw_ghostty] do
    Show.start_ghostty_terminal(socket)
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

    case resolve_session_info(ws, sid) do
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

  defp resolve_session_info(ws, sid) do
    case Terminals.resolve(sid) do
      {:ok, %SessionInfo{kind: :execution}} = ok ->
        ok

      {:ok, %SessionInfo{kind: :shell} = info} ->
        case SessionDirectory.fetch(ws.id, sid, workspace_names: [ws.name, ws.id]) do
          {:ok, %SessionInfo{} = scanned} -> {:ok, scanned}
          :error -> {:ok, %{info | workspace_id: ws.id}}
        end

      {:ok, %SessionInfo{}} = ok ->
        ok

      :error ->
        SessionDirectory.fetch(ws.id, sid, workspace_names: [ws.name, ws.id])
    end
  end

  def tmux_session_for_info(%SessionInfo{kind: :execution, tmux_session: tmux}, _workspace_name)
      when is_binary(tmux),
      do: tmux

  def tmux_session_for_info(%SessionInfo{kind: :shell, tmux_session: tmux}, _workspace_name)
      when is_binary(tmux) and tmux != "",
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

  defdelegate tmux_mutations_enabled?(kind), to: ModePolicy

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

  @doc """
  Assigns the directory's cached tab list (cheap — no tmux/git subprocesses).

  Session-switch events go through here: the directory's 2s poll plus its
  `sessions_updated` broadcast keep the list fresh, so forcing a recompute on
  every click only blocked the LiveView behind a subprocess fan-out. Use
  `refresh_session_tabs/1` when the caller just changed what tmux knows
  (created a session, explicit refresh button).
  """
  def assign_session_tabs(socket) do
    ws = socket.assigns.workspace

    tabs =
      if connected?(socket) do
        SessionDirectory.tabs(ws.id, workspace_name: ws.name || ws.id)
      else
        SessionDirectory.read(ws.id, workspace_name: ws.name || ws.id)
      end

    assign_session_tabs(socket, tabs)
  end

  @doc "Forces a directory recompute (subprocess fan-out) and assigns the result."
  def refresh_session_tabs(socket) do
    ws = socket.assigns.workspace

    tabs =
      if connected?(socket) do
        SessionDirectory.refresh_now(ws.id, workspace_name: ws.name || ws.id)
      else
        SessionDirectory.read(ws.id, workspace_name: ws.name || ws.id)
      end

    assign_session_tabs(socket, tabs)
  end

  @doc "Applies the viewer filter + view-model mapping to a canonical tab list."
  def assign_session_tabs(socket, tabs) when is_list(tabs) do
    vm =
      tabs
      |> Terminals.visible_tabs(socket.assigns[:default_terminal_sid])
      |> SessionBarVM.session_tabs()

    socket
    |> notify_newly_quiet_windows(tabs)
    |> assign(:session_tabs, vm)
    |> assign_page_title()
  end

  # OS-notification path for quiet-agent windows: diff the quiet set against
  # the previous assign and push one browser event per *transition*. Diffing
  # raw tabs (not the vm) on purpose — the viewer filter hides this tab's own
  # attached session, which is exactly where the viewer's agents run. The
  # first assign only records a baseline, so reconnects/mounts never replay
  # "went quiet 20 minutes ago" notifications.
  defp notify_newly_quiet_windows(socket, tabs) do
    quiet = quiet_window_entries(tabs)
    previous = socket.assigns[:quiet_window_ids]
    socket = assign(socket, :quiet_window_ids, MapSet.new(Map.keys(quiet)))

    if is_nil(previous) or not connected?(socket) do
      socket
    else
      workspace = socket.assigns[:workspace]
      workspace_name = (workspace && (workspace.name || workspace.id)) || ""

      quiet
      |> Enum.reject(fn {key, _entry} -> MapSet.member?(previous, key) end)
      |> Enum.reduce(socket, fn {_key, entry}, acc ->
        push_event(acc, "devide:agent_quiet", Map.put(entry, :workspace, workspace_name))
      end)
    end
  end

  defp quiet_window_entries(tabs) do
    for %SessionInfo{metadata: metadata, tmux_session: tmux_session} = info <- tabs,
        is_map(metadata),
        window <- Map.get(metadata, :windows) || Map.get(metadata, "windows") || [],
        (Map.get(window, :quiet) || Map.get(window, "quiet")) == true,
        into: %{} do
      window_id = Map.get(window, :id) || Map.get(window, "id")

      {{info.sid, window_id},
       %{
         session_id: info.sid,
         tmux_session: tmux_session,
         window_id: window_id,
         window: Map.get(window, :name) || Map.get(window, "name") || "window"
       }}
    end
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
        "host" => host_query_param(socket.assigns.host_id),
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

  defp host_query_param(host_id) when host_id in [nil, "", "local"], do: nil
  defp host_query_param(host_id), do: host_id

  @doc """
  Viewer-filtered session tabs for the workspace, read directly from the
  domain (no directory process). Used for the disconnected first render;
  connected sockets go through `assign_session_tabs/1`.
  """
  def terminal_session_tabs(workspace, default_sid) do
    workspace.id
    |> SessionDirectory.read(workspace_name: workspace.name || workspace.id)
    |> Terminals.visible_tabs(default_sid)
  end

  def subscribe_session_tabs(socket) do
    if connected?(socket) do
      ws = socket.assigns.workspace
      _ = Terminals.subscribe_session_tabs(ws.id, workspace_name: ws.name || ws.id)
    end

    socket
  end
end
