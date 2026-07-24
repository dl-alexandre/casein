defmodule CaseinWeb.WorkspaceLive.Show.FilePaneEvents do
  # File-pane overlay handle_event/handle_info clauses, delegated from
  # CaseinWeb.WorkspaceLive.Show (mirrors how FileEvents/PreviewPaneEvents are
  # delegated). Owns:
  #
  #   * the generic "pane:input" event for feature panes — authorized via
  #     Casein.Panes.get_by_pane/1 + workspace-alias match, then dispatched by
  #     pane type: :file inputs go through Pane.impl(:file).handle_input/2
  #     (`save` additionally gated by Policy.can_edit_file?, mirroring
  #     FileEvents "file:save"), :preview inputs are handled by
  #     PreviewPaneEvents.dispatch_preview_input/3;
  #   * "tree:open_in_pane" — the context-menu entry point that splits/reuses a
  #     file pane next to the active plain-terminal pane, falling back to
  #     today's "tree:open" (files tab) when no live tmux pane exists;
  #   * "terminal:open_file_link" — click (or Cmd/Ctrl+Click; Shift flips the
  #     surface) on a scanner-detected path in terminal output (delegated
  #     through TerminalEvents). Re-validates the path via
  #     Casein.FilePanes.LinkResolver (never trusts the client),
  #     anchors on the emitting pane, and opens the file at :line in a file
  #     pane; unresolvable links fall back to the files tab;
  #   * {:pane_event, evt} PubSub (Casein.Panes.Events) — maintains the
  #     :feature_panes assign and pushes "file-pane:loaded" (broadcast-with-id,
  #     filtered client-side by pane id like ghostty:render) when a file pane's
  #     active tab changes/loads. The :heartbeat reason refreshes state without
  #     any focus churn.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import CaseinWeb.WorkspaceLive.Show.Context

  alias Casein.FilePanes
  alias Casein.FilePanes.LinkResolver
  alias Casein.Files.BrowserViewable
  alias Casein.Panes
  alias Casein.Panes.Pane
  alias Casein.Policy
  alias Casein.Previews
  alias Casein.Workspaces
  alias CaseinWeb.WorkspaceLive.Show.FileEvents
  alias CaseinWeb.WorkspaceLive.Show.PreviewPaneEvents
  alias CaseinWeb.WorkspaceLive.Show.TerminalChrome
  alias CaseinWeb.WorkspaceLive.Show.TerminalState

  # --- handle_event -------------------------------------------------------------

  def handle_event("pane:input", params, socket) do
    pane_id = event_pane_id(params)
    input = Map.drop(params, ["pane-id", "pane_id"])

    with true <- is_binary(pane_id) and pane_id != "",
         {type, payload} when type in [:file, :preview] <- Panes.get_by_pane(pane_id),
         true <- pane_workspace_match?(socket, feature_value(payload, :workspace_id)) do
      case type do
        :file -> dispatch_file_input(socket, pane_id, payload, input)
        :preview -> PreviewPaneEvents.dispatch_preview_input(socket, pane_id, input)
      end
    else
      _ ->
        # Unknown pane, unknown pane type, or another workspace's pane: refuse.
        {:reply, %{error: "not_found"}, socket}
    end
  end

  # Viewer-local dirty tracking. Deliberately NOT routed through
  # Pane.impl(:file).handle_input/2: dirty describes this browser's unsaved
  # CodeMirror buffer, not the persisted file pane, so it must never touch the
  # shared registry payload. Authorized like "pane:input" (pane exists, is a
  # file pane, belongs to this workspace), then stored in the :file_pane_dirty
  # socket assign.
  def handle_event("file-pane:dirty", params, socket) do
    pane_id = event_pane_id(params)
    path = params["path"]

    with true <- is_binary(pane_id) and pane_id != "",
         true <- is_binary(path) and path != "",
         {:file, payload} <- Panes.get_by_pane(pane_id),
         true <- pane_workspace_match?(socket, feature_value(payload, :workspace_id)) do
      {:noreply, put_file_pane_dirty(socket, pane_id, path, params["dirty"] == true)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("tree:open_in_pane", %{"path" => path} = params, socket)
      when is_binary(path) do
    tmux_session = socket.assigns[:tmux_session]
    anchor = anchor_pane_id(socket)

    if is_binary(tmux_session) and tmux_session != "" and is_binary(anchor) do
      opts =
        [
          tmux_session: tmux_session,
          anchor_pane_id: anchor,
          line: parse_line(params["line"]),
          actor_id: current_actor_id(socket)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case FilePanes.open_file_in_pane(socket.assigns.workspace, path, opts) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> assign(:tab, "terminal")
           |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)}

        {:error, reason} when reason in [:no_tmux_session, :no_active_pane, :window_not_found] ->
          open_in_files_tab(socket, path)

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Could not open file in a pane: #{format_file_error(reason)}"
           )}
      end
    else
      # No live tmux pane to anchor a split on — today's behavior (files tab).
      open_in_files_tab(socket, path)
    end
  end

  def handle_event("tree:open_in_pane", _params, socket), do: {:noreply, socket}

  def handle_event("terminal:open_file_link", %{"path" => path} = params, socket)
      when is_binary(path) do
    line = parse_line(params["line"])
    mode = link_mode(params["mode"])

    case local_link_root(socket.assigns.workspace) do
      {:ok, root} ->
        # Never trust the client payload: re-validate through the same
        # resolver that admitted the link when the frame was scanned.
        case LinkResolver.resolve(root, path) do
          {:ok, rel} ->
            surface =
              case mode do
                :flip -> BrowserViewable.other(BrowserViewable.surface(rel))
                _ -> BrowserViewable.surface(rel)
              end

            case surface do
              :preview -> open_link_in_preview(socket, rel, params)
              :file -> open_link_in_pane(socket, rel, line, params)
            end

          {:error, :not_found} ->
            # Existed at scan time but vanished (or a stale client store):
            # the files-tab fallback surfaces the read error in place.
            open_in_files_tab(socket, path)

          {:error, _refused} ->
            # Confinement failure (outside root / symlink escape / invalid):
            # refuse outright — no files-tab retry for a forged path.
            {:noreply, put_flash(socket, :error, "That link points outside the workspace.")}
        end

      _ ->
        # No local root (remote workspace): link scanning is disabled there,
        # so treat this as a plain open request. The files tab validates the
        # path through FileAccess itself.
        open_in_files_tab(socket, path)
    end
  end

  def handle_event("terminal:open_file_link", _params, socket), do: {:noreply, socket}

  # --- handle_info --------------------------------------------------------------

  def handle_info({:pane_event, evt}, socket) do
    if pane_workspace_match?(socket, evt.workspace_id) do
      socket =
        socket
        |> update_feature_panes(evt)
        |> reconcile_file_pane_dirty()

      socket =
        case evt.type do
          # Preview reactions (heartbeat focus guard, highlight/surface/focus
          # restore, URL-change soft reload, entered-pane cleanup) live with
          # the rest of the preview web logic.
          :preview ->
            PreviewPaneEvents.apply_pane_event(socket, evt)

          _ ->
            socket
            |> maybe_push_file_pane_loaded(evt)
            |> maybe_apply_registered_focus(evt)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # --- assign maintenance ---------------------------------------------------------

  defp update_feature_panes(socket, %{reason: :removed, pane_id: pane_id}) do
    assign(socket, :feature_panes, Map.delete(feature_panes(socket), pane_id))
  end

  defp update_feature_panes(socket, evt) do
    assign(
      socket,
      :feature_panes,
      Map.put(feature_panes(socket), evt.pane_id, %{type: evt.type, payload: evt.payload})
    )
  end

  # Keep :file_pane_dirty honest after any feature-pane change: drop dirty
  # markers whose {pane_id, path} no longer names a live tab (tab closed, pane
  # removed). Cheap set intersection over the current file-pane tabs.
  defp reconcile_file_pane_dirty(socket) do
    dirty = file_pane_dirty(socket)

    if MapSet.size(dirty) == 0 do
      socket
    else
      valid =
        for {pane_id, %{type: :file} = entry} <- feature_panes(socket),
            %{path: path} <- TerminalChrome.file_pane_tabs(entry),
            into: MapSet.new(),
            do: {pane_id, path}

      assign(socket, :file_pane_dirty, MapSet.intersection(dirty, valid))
    end
  end

  defp put_file_pane_dirty(socket, pane_id, path, true),
    do: assign(socket, :file_pane_dirty, MapSet.put(file_pane_dirty(socket), {pane_id, path}))

  defp put_file_pane_dirty(socket, pane_id, path, false),
    do: assign(socket, :file_pane_dirty, MapSet.delete(file_pane_dirty(socket), {pane_id, path}))

  defp file_pane_dirty(socket), do: socket.assigns[:file_pane_dirty] || MapSet.new()

  # Push the active tab's fresh content to the overlay hooks. Broadcast-with-id:
  # every FilePaneOverlay instance receives it and filters on payload.pane_id.
  defp maybe_push_file_pane_loaded(socket, %{type: :file, reason: reason} = evt)
       when reason in [:registered, :updated, :heartbeat] do
    case loaded_payload(evt.pane_id, evt.payload) do
      nil -> socket
      payload -> push_event(socket, "file-pane:loaded", payload)
    end
  end

  defp maybe_push_file_pane_loaded(socket, _evt), do: socket

  # A newly registered file pane behaves like a newly registered preview: it is
  # UI-highlighted, and the Ghostty surface/operator focus are re-derived so the
  # holder pane can never capture them. Explicitly NOT done for :heartbeat or
  # :updated — a tab switch or CLI heartbeat must not churn tmux focus.
  defp maybe_apply_registered_focus(socket, %{type: :file, reason: :registered} = evt) do
    feature_map =
      TerminalChrome.feature_pane_map(
        socket.assigns[:preview_panes] || %{},
        feature_panes(socket)
      )

    active_window_panes =
      TerminalChrome.active_tmux_window_panes(socket.assigns[:tmux_windows] || [])

    socket
    |> assign(:ui_highlight_pane_id, evt.pane_id)
    |> assign(
      :terminal_surface_pane_id,
      TerminalChrome.terminal_surface_pane_id(
        active_window_panes,
        feature_map,
        socket.assigns[:tmux_active_pane_id],
        socket.assigns[:terminal_surface_pane_id]
      )
    )
    |> TerminalState.restore_operator_tmux_focus(feature_map)
  end

  defp maybe_apply_registered_focus(socket, _evt), do: socket

  # --- pane:input dispatch --------------------------------------------------------

  # Hook-mount hydration: reply with the active tab so a reconnect/remount gets
  # content without waiting for the next registry broadcast.
  defp dispatch_file_input(socket, pane_id, payload, %{"type" => "hydrate"}) do
    {:reply, %{active: loaded_payload(pane_id, payload)}, socket}
  end

  defp dispatch_file_input(socket, pane_id, _payload, %{"type" => "save"} = input) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.save",
        target_type: "file_pane",
        target_ref: input["path"]
      })

    if Casein.Policy.Decision.allow?(decision) do
      case Pane.impl(:file).handle_input(pane_id, input) do
        :ok ->
          {:reply, %{ok: true}, socket}

        {:error, :conflict} ->
          # Optimistic-concurrency conflict passes through unchanged so the
          # client can distinguish it (keep buffer, surface the conflict).
          {:reply, %{error: "conflict"}, socket}

        {:error, reason} ->
          {:reply, %{error: format_file_error(reason)}, socket}
      end
    else
      {:reply, %{error: "not_allowed"}, socket}
    end
  end

  defp dispatch_file_input(socket, pane_id, _payload, %{"type" => type} = input)
       when type in ["open_tab", "activate_tab", "close_tab", "goto_line", "reload"] do
    case Pane.impl(:file).handle_input(pane_id, input) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "File pane action failed: #{format_file_error(reason)}")}
    end
  end

  defp dispatch_file_input(socket, _pane_id, _payload, _input) do
    {:reply, %{error: "unsupported_input"}, socket}
  end

  # --- terminal:open_file_link helpers ---------------------------------------------

  defp local_link_root(workspace) do
    case Workspaces.safe_host_loc(workspace) do
      {:ok, {:local, root}} when is_binary(root) and root != "" -> {:ok, root}
      _ -> :error
    end
  end

  defp link_mode("flip"), do: :flip
  defp link_mode(:flip), do: :flip
  defp link_mode(_), do: :default

  defp open_link_in_pane(socket, rel, line, params) do
    tmux_session = socket.assigns[:tmux_session]
    anchor = link_anchor_pane_id(socket, params)

    if is_binary(tmux_session) and tmux_session != "" and is_binary(anchor) do
      opts =
        [
          tmux_session: tmux_session,
          anchor_pane_id: anchor,
          line: line,
          actor_id: current_actor_id(socket)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case FilePanes.open_file_in_pane(socket.assigns.workspace, rel, opts) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> assign(:tab, "terminal")
           |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)}

        {:error, reason} when reason in [:no_tmux_session, :no_active_pane, :window_not_found] ->
          open_in_files_tab(socket, rel)

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Could not open file in a pane: #{format_file_error(reason)}"
           )}
      end
    else
      open_in_files_tab(socket, rel)
    end
  end

  # Open a browser-viewable path in a :preview pane pointed at the per-workspace
  # static file server. Fallbacks mirror open_link_in_pane: no tmux/anchor →
  # files tab; confinement is already enforced by LinkResolver upstream.
  defp open_link_in_preview(socket, rel, params) do
    tmux_session = socket.assigns[:tmux_session]
    anchor = link_anchor_pane_id(socket, params)

    if is_binary(tmux_session) and tmux_session != "" and is_binary(anchor) do
      case Previews.ensure_started(socket.assigns.workspace, tmux_session: tmux_session) do
        {:ok, port} ->
          url = "http://127.0.0.1:#{port}/" <> URI.encode(rel)

          case PreviewPaneEvents.split_workspace_preview(socket, url, params) do
            {:ok, socket} ->
              {:noreply, assign(socket, :tab, "terminal")}

            {:error, reason, socket}
            when reason in [:no_tmux_session, :no_active_pane, :window_not_found] ->
              open_in_files_tab(socket, rel)

            {:error, reason, socket} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "Could not open file in a preview pane: #{format_file_error(reason)}"
               )}
          end

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Could not start file preview server: #{format_file_error(reason)}"
           )}
      end
    else
      open_in_files_tab(socket, rel)
    end
  end

  # Anchor identity for the split: the payload's pane_id when it names a live
  # plain-terminal tmux pane (the frame key is primary); otherwise map the
  # click's {row, col} grid cell onto the active window's pane rectangles —
  # the shared Ghostty surface renders the WHOLE tmux window (splits drawn by
  # tmux inside one grid), so this is the same cell geometry tmux_pane_style/2
  # renders from. Last resort: the surface/active-pane fallback.
  defp link_anchor_pane_id(socket, params) do
    panes = TerminalChrome.active_tmux_window_panes(socket.assigns[:tmux_windows] || [])
    pane_id = params["pane_id"]

    cond do
      operator_tmux_pane?(socket, panes, pane_id) ->
        pane_id

      pane = link_pane_at_cell(socket, panes, params["row"], params["col"]) ->
        pane.id

      true ->
        anchor_pane_id(socket)
    end
  end

  defp operator_tmux_pane?(socket, panes, pane_id) do
    is_binary(pane_id) and pane_id != "" and
      Enum.any?(panes, &(&1.id == pane_id)) and
      not link_feature_pane?(socket, pane_id)
  end

  defp link_pane_at_cell(socket, panes, row, col) do
    with {:ok, row} <- cell_int(row),
         {:ok, col} <- cell_int(col) do
      Enum.find(panes, fn pane ->
        cell_in_pane?(pane, row, col) and not link_feature_pane?(socket, pane.id)
      end)
    else
      _ -> nil
    end
  end

  defp cell_in_pane?(pane, row, col) do
    left = TerminalChrome.tmux_dimension(pane.left)
    top = TerminalChrome.tmux_dimension(pane.top)
    width = TerminalChrome.tmux_dimension(pane.width)
    height = TerminalChrome.tmux_dimension(pane.height)

    col >= left and col < left + width and row >= top and row < top + height
  end

  defp link_feature_pane?(socket, pane_id) do
    TerminalChrome.feature_pane?(
      socket.assigns[:preview_panes] || %{},
      feature_panes(socket),
      pane_id
    )
  end

  defp cell_int(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp cell_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp cell_int(_value), do: :error

  # --- helpers --------------------------------------------------------------------

  defp feature_panes(socket), do: socket.assigns[:feature_panes] || %{}

  defp open_in_files_tab(socket, path) do
    {:noreply, socket} = FileEvents.handle_event("tree:open", %{"path" => path}, socket)
    {:noreply, assign(socket, :tab, "files")}
  end

  # Anchor for the split: the pane hosting the Ghostty surface (by definition
  # the active plain-terminal pane), falling back to the tmux-active pane when
  # it is not a feature pane. nil when no live topology exists yet.
  defp anchor_pane_id(socket) do
    surface = socket.assigns[:terminal_surface_pane_id]
    active = socket.assigns[:tmux_active_pane_id]

    feature? =
      TerminalChrome.feature_pane?(
        socket.assigns[:preview_panes] || %{},
        feature_panes(socket),
        active
      )

    cond do
      is_binary(surface) and surface != "" -> surface
      is_binary(active) and active != "" and not feature? -> active
      true -> nil
    end
  end

  defp loaded_payload(pane_id, payload) do
    case feature_value(payload, :active) do
      %{} = active ->
        %{
          pane_id: pane_id,
          path: feature_value(active, :path),
          content: feature_value(active, :content),
          version: feature_value(active, :version),
          line: feature_value(active, :line),
          error: format_active_error(feature_value(active, :error))
        }

      _ ->
        nil
    end
  end

  defp format_active_error(nil), do: nil
  defp format_active_error(reason), do: format_file_error(reason)

  # One alias gate for every pane event, preview or file: the workspace's own
  # id, its viewer aliases, and the folder alias of the resolved host path
  # (matches the preview subscription set, so folder-attached viewers keep
  # receiving events for linked workspaces).
  defp pane_workspace_match?(socket, workspace_id),
    do: PreviewPaneEvents.pane_event_workspace_match?(socket, workspace_id)

  defp event_pane_id(%{"pane-id" => pane_id}) when is_binary(pane_id), do: pane_id
  defp event_pane_id(%{"pane_id" => pane_id}) when is_binary(pane_id), do: pane_id
  defp event_pane_id(_params), do: nil

  defp parse_line(value) when is_integer(value) and value > 0, do: value

  defp parse_line(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_line(_value), do: nil

  defp feature_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp feature_value(_map, _key), do: nil
end
