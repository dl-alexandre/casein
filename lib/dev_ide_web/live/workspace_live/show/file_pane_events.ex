defmodule DevIdeWeb.WorkspaceLive.Show.FilePaneEvents do
  # File-pane overlay handle_event/handle_info clauses, delegated from
  # DevIdeWeb.WorkspaceLive.Show (mirrors how FileEvents/PreviewPaneEvents are
  # delegated). Owns:
  #
  #   * the generic "pane:input" event for :file feature panes — authorized via
  #     DevIDE.Panes.get_by_pane/1 + workspace-alias match, `save` additionally
  #     gated by Policy.can_edit_file? (mirrors FileEvents "file:save"), then
  #     dispatched through Pane.impl(:file).handle_input/2;
  #   * "tree:open_in_pane" — the context-menu entry point that splits/reuses a
  #     file pane next to the active plain-terminal pane, falling back to
  #     today's "tree:open" (files tab) when no live tmux pane exists;
  #   * {:pane_event, evt} PubSub (DevIDE.Panes.Events) — maintains the
  #     :feature_panes assign and pushes "file-pane:loaded" (broadcast-with-id,
  #     filtered client-side by pane id like ghostty:render) when a file pane's
  #     active tab changes/loads. The :heartbeat reason refreshes state without
  #     any focus churn.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import DevIdeWeb.WorkspaceLive.Show.Context

  alias DevIDE.FilePanes
  alias DevIDE.Panes
  alias DevIDE.Panes.Pane
  alias DevIDE.Policy
  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases
  alias DevIdeWeb.WorkspaceLive.Show.FileEvents
  alias DevIdeWeb.WorkspaceLive.Show.TerminalChrome
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  # --- handle_event -------------------------------------------------------------

  def handle_event("pane:input", params, socket) do
    pane_id = event_pane_id(params)
    input = Map.drop(params, ["pane-id", "pane_id"])

    with true <- is_binary(pane_id) and pane_id != "",
         {:file, payload} <- Panes.get_by_pane(pane_id),
         true <- pane_workspace_match?(socket, feature_value(payload, :workspace_id)) do
      dispatch_file_input(socket, pane_id, payload, input)
    else
      _ ->
        # Unknown pane, non-file pane (previews keep their legacy events until
        # the runtime cutover), or another workspace's pane: refuse.
        {:reply, %{error: "not_found"}, socket}
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

  # --- handle_info --------------------------------------------------------------

  def handle_info({:pane_event, evt}, socket) do
    if pane_workspace_match?(socket, evt.workspace_id) do
      {:noreply,
       socket
       |> update_feature_panes(evt)
       |> maybe_push_file_pane_loaded(evt)
       |> maybe_apply_registered_focus(evt)}
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

    if DevIDE.Policy.Decision.allow?(decision) do
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

  defp pane_workspace_match?(socket, workspace_id) when is_binary(workspace_id) do
    ws_id = socket.assigns.workspace.id

    workspace_id == ws_id or
      workspace_id in WorkspaceAliases.viewer_ids(ws_id)
  end

  defp pane_workspace_match?(_socket, _workspace_id), do: false

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
