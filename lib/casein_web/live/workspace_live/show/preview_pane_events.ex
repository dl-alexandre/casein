defmodule CaseinWeb.WorkspaceLive.Show.PreviewPaneEvents do
  # Preview-pane web logic, delegated from CaseinWeb.WorkspaceLive.Show.
  #
  # Since the preview runtime cutover, preview lifecycle flows through the
  # generic feature-pane pipeline:
  #
  #   * registration/heartbeat/update/removal → Casein.Panes.Events
  #     (`apply_pane_event/2`, invoked from FilePaneEvents' {:pane_event, _}
  #     handler), which maintains the derived :preview_panes assign;
  #   * back/forward/refresh/close/recover → the generic "pane:input" event
  #     (`dispatch_preview_input/3`); the legacy "preview-pane:*" names are
  #     thin translations kept for the session-bar buttons;
  #   * mount hydration → Panes.snapshot/1 (`load_feature_panes/2` +
  #     `preview_panes_from_feature/1`).
  #
  # Channels consciously kept preview-only (they survive the cutover because
  # they are browser/preview domain concerns, not pane lifecycle):
  #
  #   * {:preview_observation, _} — live browser url/title pushed by
  #     PreviewCtl on the legacy "preview:" topic; enriches the derived assign
  #     (titles have no registry backing to flow through Panes.Events);
  #   * {:browser_control, _} — MCP browser-control side channel (agent-driven
  #     iframe reload / page reload / pane focus / visible click actions);
  #   * "preview:open", "preview-pane:enter/exit/telemetry/snapshot-click" —
  #     overlay UX + PreviewActivity feed for iframes/snapshots.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import CaseinWeb.WorkspaceLive.Show.Context

  alias Casein.Agents
  alias Casein.Panes
  alias Casein.Panes.Pane
  alias Casein.PreviewActivity
  alias Casein.PreviewPanes
  alias Casein.Workspaces.Aliases, as: WorkspaceAliases
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.TerminalChrome
  alias CaseinWeb.WorkspaceLive.Show.TerminalState

  def handle_event("preview:open", %{"surface" => surface} = params, socket) do
    open_surface_preview(socket, surface, params)
  end

  def handle_event("preview:open", %{"url" => _url} = params, socket) do
    open_preview(socket, params)
  end

  # enter/exit/telemetry/snapshot-click are consciously preview-only (they
  # survive the runtime cutover): overlay UX state (the entered-pane CSS mode)
  # and the PreviewActivity feed are iframe/snapshot concerns with no generic
  # pane equivalent.
  def handle_event("preview-pane:enter", params, socket) do
    case event_pane_id(params) do
      pane_id when is_binary(pane_id) ->
        record_preview_activity(socket, pane_id, "selected", %{"source" => "overlay"})
        {:noreply, assign(socket, :entered_preview_pane_id, pane_id)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("preview-pane:exit", params, socket) do
    case event_pane_id(params) do
      pane_id when is_binary(pane_id) ->
        record_preview_activity(socket, pane_id, "exited", %{"source" => "overlay"})
        {:noreply, maybe_clear_entered_preview_pane(socket, pane_id)}

      _ ->
        {:noreply, socket}
    end
  end

  # Thin translations into the generic pane:input route (single authorization
  # and dispatch path). The session-bar header buttons still emit the legacy
  # event names; the overlay hook emits pane:input directly.
  def handle_event("preview-pane:back", params, socket),
    do: legacy_preview_input(socket, params, "go_back")

  def handle_event("preview-pane:forward", params, socket),
    do: legacy_preview_input(socket, params, "go_forward")

  def handle_event("preview-pane:refresh", params, socket),
    do: legacy_preview_input(socket, params, "reload")

  def handle_event("preview-pane:recover", params, socket),
    do: legacy_preview_input(socket, params, "recover")

  def handle_event("preview-pane:close", params, socket),
    do: legacy_preview_input(socket, params, "close")

  def handle_event("preview-pane:telemetry", params, socket) do
    case event_pane_id(params) do
      pane_id when is_binary(pane_id) ->
        metadata =
          params
          |> Map.get("metadata", %{})
          |> sanitize_preview_telemetry_metadata()
          |> Map.merge(%{
            "mode" => Map.get(params, "mode"),
            "url" => Map.get(params, "url")
          })
          |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
          |> Map.new()

        params
        |> Map.get("event", "interaction")
        |> then(&record_preview_activity(socket, pane_id, &1, metadata))

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("preview-pane:snapshot-click", params, socket) do
    case event_pane_id(params) do
      pane_id when is_binary(pane_id) ->
        coords = %{
          "x" => Map.get(params, "x"),
          "y" => Map.get(params, "y")
        }

        record_preview_activity(socket, pane_id, "snapshot_click", coords)

        socket =
          with :ok <- authorize_preview_pane(socket, pane_id),
               {:ok, registration} <- PreviewPanes.click_snapshot(pane_id, coords) do
            pane = preview_pane_payload(registration)

            socket
            |> assign(
              :preview_panes,
              Map.put(socket.assigns[:preview_panes] || %{}, pane.pane_id, pane)
            )
            |> push_event("casein:reload_preview_iframes", %{
              "action" => "reload_preview_iframe",
              "force" => true,
              "pane_id" => pane_id,
              "workspace_id" => socket.assigns.workspace.id
            })
          else
            _ -> socket
          end

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # Legacy "preview:" lifecycle messages still arrive (the registry
  # dual-broadcasts so its non-LiveView consumers keep working), but the
  # LiveView's preview state is maintained exclusively from the generic
  # Casein.Panes.Events channel (`apply_pane_event/2`). No-op, don't crash.
  def handle_info({:preview_pane_registered, _payload}, socket), do: {:noreply, socket}
  def handle_info({:preview_pane_removed, _payload}, socket), do: {:noreply, socket}

  # Consciously preview-only (survives the runtime cutover): agent-driven
  # browser observations carry the live page's url/title, which exist only in
  # the browser-control session — there is no registry state to flow through
  # Panes.Events. They enrich the derived :preview_panes assign (and push the
  # iframe reload on a URL change) exactly as before; the next registry
  # broadcast for the pane rebuilds the entry from registry truth, which is
  # also the legacy behavior.
  def handle_info(
        {:preview_observation,
         %{preview_id: preview_id, session_id: _session_id, observation: observation}},
        socket
      )
      when is_binary(preview_id) do
    case find_preview_panes_by_preview_id(socket, preview_id) do
      [] ->
        # Workspace isn't currently showing this preview — nothing to update.
        {:noreply, socket}

      matches ->
        {preview_panes, reload_pane_ids} =
          Enum.reduce(matches, {socket.assigns[:preview_panes] || %{}, []}, fn {pane_id, pane},
                                                                               {panes, reloads} ->
            updated =
              apply_observation_to_preview_pane(socket.assigns.workspace, pane, observation)

            reloads =
              if preview_pane_url_changed?(pane, updated), do: [pane_id | reloads], else: reloads

            {Map.put(panes, pane_id, updated), reloads}
          end)

        socket = assign(socket, :preview_panes, preview_panes)

        socket =
          Enum.reduce(reload_pane_ids, socket, fn pane_id, acc ->
            push_event(acc, "casein:reload_preview_iframes", %{"pane_id" => pane_id})
          end)

        {:noreply, socket}
    end
  end

  def handle_info({:preview_observation, _payload}, socket), do: {:noreply, socket}

  # The {:browser_control, _} clauses below are consciously preview-only
  # (they survive the runtime cutover): they are the MCP browser-control side
  # channel — agent tools pushing UI effects at the viewer — not pane
  # lifecycle, and their non-LiveView consumers share the same topic.
  def handle_info({:browser_control, %{"action" => "reload_preview_iframe"} = payload}, socket) do
    # An explicit agent reload tool: force the frame to reload even when the URL
    # is unchanged (the soft path only re-points src on a real URL change).
    {:noreply,
     push_event(socket, "casein:reload_preview_iframes", Map.put(payload, "force", true))}
  end

  def handle_info({:browser_control, %{"action" => "reload_page"} = payload}, socket) do
    {:noreply, push_event(socket, "casein:reload_page", payload)}
  end

  def handle_info({:browser_control, %{"action" => "focus_preview_pane"} = payload}, socket) do
    {:noreply,
     TerminalState.focus_activity_target(
       socket,
       Map.get(payload, "tmux_session"),
       Map.get(payload, "pane_id")
     )}
  end

  def handle_info({:browser_control, %{"action" => "preview_pane_action"} = payload}, socket) do
    {:noreply, push_event(socket, "casein:preview_pane_action", payload)}
  end

  @doc false
  # Preview branch of the generic {:pane_event, evt} handler — the runtime
  # cutover replacement for the legacy {:preview_pane_registered/_removed}
  # clauses, one-for-one:
  #
  #   * :registered/:updated with a changed display URL → highlight the pane,
  #     re-derive the Ghostty surface pane and restore operator tmux focus
  #     (exactly the legacy non-heartbeat branch);
  #   * :heartbeat — or any event whose display URL is unchanged (legacy CLI
  #     heartbeats were detected that way) — refreshes the registration fields
  #     without focus churn;
  #   * a display-URL change on a known pane pushes the generic soft-reload
  #     event: the overlay root is phx-update="ignore", so the iframe only
  #     follows registry navigation through this push (it re-points src only
  #     when it actually changed);
  #   * :removed drops the pane, clears the entered state and re-derives the
  #     terminal surface pane.
  def apply_pane_event(socket, %{type: :preview, reason: :removed} = evt) do
    socket
    |> assign(:preview_panes, Map.delete(socket.assigns[:preview_panes] || %{}, evt.pane_id))
    |> maybe_clear_entered_preview_pane(evt.pane_id)
    |> refresh_terminal_surface_pane_id()
  end

  def apply_pane_event(socket, %{type: :preview} = evt) do
    pane =
      evt.payload
      |> Map.put_new(:pane_id, evt.pane_id)
      |> Map.put_new(:workspace_id, evt.workspace_id)
      |> preview_pane_payload()

    existing = Map.get(socket.assigns[:preview_panes] || %{}, pane.pane_id)

    socket =
      assign(
        socket,
        :preview_panes,
        Map.put(socket.assigns[:preview_panes] || %{}, pane.pane_id, pane)
      )

    socket =
      if is_map(existing) and preview_pane_url_changed?(existing, pane) do
        push_event(socket, "casein:reload_preview_iframes", %{"pane_id" => pane.pane_id})
      else
        socket
      end

    if evt.reason == :heartbeat or preview_pane_heartbeat?(existing, pane) do
      # A pure heartbeat (same display URL): keep the latest fields but don't
      # re-highlight or restore tmux focus, which re-enters the focus path and
      # churns the live preview on every heartbeat.
      socket
    else
      socket
      |> assign(:ui_highlight_pane_id, pane.pane_id)
      |> refresh_terminal_surface_pane_id()
      |> TerminalState.restore_operator_tmux_focus()
    end
  end

  def apply_pane_event(socket, _evt), do: socket

  @doc false
  # Mount/reconnect hydration for the generic :feature_panes assign: the
  # Panes.snapshot/1 fold merged over every workspace id this viewer aliases
  # (same id set the legacy preview loader used, so folder/manager-attached
  # viewers keep seeing linked preview panes).
  def load_feature_panes(%{id: workspace_id} = workspace, path_result) do
    workspace
    |> preview_pane_workspace_ids(workspace_id, path_result)
    |> Enum.reduce(%{}, fn id, acc -> Map.merge(acc, Panes.snapshot(id)) end)
  end

  @doc false
  # The legacy-shaped :preview_panes assign derived from :feature_panes — the
  # session bar, terminal chrome and focus logic keep consuming the enriched
  # preview map (title/favicon added) while lifecycle flows only through
  # Panes.Events.
  def preview_panes_from_feature(feature_panes) do
    for {pane_id, %{type: :preview, payload: payload}} <- feature_panes || %{}, into: %{} do
      {pane_id, preview_pane_payload(Map.put_new(payload, :pane_id, pane_id))}
    end
  end

  @doc false
  # Workspace-alias gate for generic pane events (and legacy preview infos):
  # accepts the workspace's own id, its viewer aliases, and the folder alias of
  # the resolved host path.
  def pane_event_workspace_match?(socket, workspace_id),
    do: preview_pane_workspace_match?(socket, workspace_id)

  @doc false
  def preview_subscription_workspace_ids(socket) do
    socket.assigns.workspace
    |> preview_pane_workspace_ids(socket.assigns.workspace.id, socket.assigns[:host_path])
    |> Enum.map(&to_string/1)
  end

  @doc false
  def split_workspace_preview(socket, url, params) do
    workspace = socket.assigns.workspace
    tmux_session = socket.assigns[:tmux_session]

    if is_binary(tmux_session) and tmux_session != "" do
      opts = [
        actor_id: current_actor_id(socket),
        viewport: Map.get(params, "viewport") || Map.get(params, :viewport),
        tmux_session: tmux_session,
        cwd: Show.terminal_window_cwd(socket)
      ]

      case Agents.split_preview_pane(workspace, url, opts) do
        {:ok, _result} ->
          {:ok,
           socket
           |> TerminalState.refresh_tmux_topology()}

        {:error, reason} ->
          {:error, reason, socket}
      end
    else
      {:error, :no_tmux_session, socket}
    end
  end

  defp event_pane_id(%{"pane-id" => pane_id}) when is_binary(pane_id), do: pane_id
  defp event_pane_id(%{"pane_id" => pane_id}) when is_binary(pane_id), do: pane_id
  defp event_pane_id(_), do: nil

  defp open_preview(socket, %{"url" => url} = params) do
    case split_workspace_preview(socket, url, params) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, :no_tmux_session, socket} ->
        {:noreply,
         put_flash(socket, :error, "Start a tmux terminal session before opening a preview pane")}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to open preview: #{inspect(reason)}")}
    end
  end

  defp open_surface_preview(socket, surface, params) do
    workspace = socket.assigns.workspace

    case Casein.Previews.get_surface(workspace, surface) do
      %{url: url} when is_binary(url) ->
        case split_workspace_preview(socket, url, params) do
          {:ok, socket} ->
            {:noreply, socket}

          {:error, :no_tmux_session, socket} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Start a tmux terminal session before opening a preview pane"
             )}

          {:error, reason, socket} ->
            {:noreply, put_flash(socket, :error, "Failed to open preview: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Preview surface not found: #{surface}")}
    end
  end

  defp refresh_terminal_surface_pane_id(socket) do
    active_window_panes =
      TerminalChrome.active_tmux_window_panes(socket.assigns[:tmux_windows] || [])

    assign(
      socket,
      :terminal_surface_pane_id,
      TerminalChrome.terminal_surface_pane_id(
        active_window_panes,
        TerminalChrome.feature_pane_map(
          socket.assigns[:preview_panes] || %{},
          socket.assigns[:feature_panes] || %{}
        ),
        socket.assigns[:tmux_active_pane_id],
        socket.assigns[:terminal_surface_pane_id]
      )
    )
  end

  defp authorize_preview_pane(socket, pane_id) do
    case PreviewPanes.get_by_pane(pane_id) do
      %{workspace_id: workspace_id} ->
        if preview_pane_workspace_match?(socket, workspace_id),
          do: :ok,
          else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp preview_pane_workspace_match?(socket, workspace_id) when is_binary(workspace_id) do
    workspace_id in preview_pane_workspace_ids(
      socket.assigns.workspace,
      socket.assigns.workspace.id,
      socket.assigns[:host_path]
    )
  end

  defp preview_pane_workspace_match?(_socket, _workspace_id), do: false

  defp preview_pane_workspace_ids(workspace, workspace_id, path_result) do
    ([workspace_id] ++
       WorkspaceAliases.viewer_ids(workspace_id) ++
       workspace_folder_aliases(workspace, path_result))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp workspace_folder_aliases(_workspace, {:ok, path}) when is_binary(path) and path != "" do
    [WorkspaceAliases.folder_id_for_path(path)]
  end

  defp workspace_folder_aliases(workspace, _path_result) do
    path =
      Map.get(workspace, :path) || Map.get(workspace, "path") || Map.get(workspace, :host_path) ||
        Map.get(workspace, "host_path")

    case path do
      path when is_binary(path) and path != "" -> [WorkspaceAliases.folder_id_for_path(path)]
      _ -> []
    end
  end

  defp preview_pane_payload(payload) do
    display_url = payload_value(payload, :display_url) || payload_value(payload, :url)

    %{
      pane_id: payload_value(payload, :pane_id),
      workspace_id: payload_value(payload, :workspace_id),
      url: payload_value(payload, :url),
      display_url: display_url,
      title: preview_pane_tab_title(payload, display_url),
      favicon_url: TerminalChrome.preview_favicon_url(display_url),
      viewport: payload_value(payload, :viewport),
      preview_id: payload_value(payload, :preview_id),
      control_session_id: payload_value(payload, :control_session_id),
      tmux_session: payload_value(payload, :tmux_session),
      shared: payload_value(payload, :shared) || false,
      source_pane_id: payload_value(payload, :source_pane_id)
    }
  end

  defp find_preview_panes_by_preview_id(socket, preview_id) do
    socket.assigns[:preview_panes]
    |> Kernel.||(%{})
    |> Enum.filter(fn {_pane_id, pane} -> preview_value(pane, :preview_id) == preview_id end)
  end

  defp apply_observation_to_preview_pane(workspace, pane, observation) do
    url = observation_field(observation, :url)
    title = observation_field(observation, :title)

    display_url =
      url
      |> then(&PreviewPanes.browser_display_url(workspace, &1))
      |> case do
        nil -> preview_value(pane, :display_url) || preview_value(pane, :url)
        "" -> preview_value(pane, :display_url) || preview_value(pane, :url)
        browser_url -> browser_url
      end

    pane
    |> maybe_put_preview_field(:url, url)
    |> maybe_put_preview_field(:display_url, display_url)
    |> maybe_put_preview_field(:title, title)
    |> Map.put(:favicon_url, TerminalChrome.preview_favicon_url(display_url))
  end

  defp maybe_put_preview_field(pane, _key, nil), do: pane
  defp maybe_put_preview_field(pane, _key, ""), do: pane
  defp maybe_put_preview_field(pane, key, value), do: Map.put(pane, key, value)

  defp observation_field(observation, key) when is_map(observation) and is_atom(key) do
    Map.get(observation, key) || Map.get(observation, Atom.to_string(key))
  end

  defp observation_field(_observation, _key), do: nil

  defp preview_pane_heartbeat?(existing, pane) when is_map(existing) do
    url = preview_value(existing, :display_url)
    is_binary(url) and url != "" and url == preview_value(pane, :display_url)
  end

  defp preview_pane_heartbeat?(_existing, _pane), do: false

  defp preview_pane_url_changed?(previous, updated) do
    new_url = preview_value(updated, :display_url)
    is_binary(new_url) and new_url != "" and new_url != preview_value(previous, :display_url)
  end

  defp preview_pane_tab_title(payload, display_url) do
    case payload_value(payload, :title) do
      title when is_binary(title) and title != "" ->
        if String.starts_with?(title, "preview "), do: nil, else: title

      _ ->
        if is_binary(display_url) and display_url != "" do
          Casein.Previews.extract_title_from_url(display_url)
        end
    end
  end

  defp record_preview_activity(socket, pane_id, event, metadata) when is_binary(pane_id) do
    preview = Map.get(socket.assigns[:preview_panes] || %{}, pane_id)
    registration = PreviewPanes.get_by_pane(pane_id)
    workspace_id = socket.assigns.workspace.id

    _ =
      PreviewActivity.record(%{
        workspace_id: workspace_id,
        pane_id: pane_id,
        preview_id:
          preview_value(preview, :preview_id) || preview_value(registration, :preview_id),
        session_id:
          preview_value(preview, :control_session_id) ||
            preview_value(registration, :control_session_id),
        source: :browser,
        event: to_string(event || "interaction"),
        summary: preview_activity_summary(event, metadata),
        metadata:
          metadata
          |> Map.put_new("title", preview_value(preview, :title))
          |> Map.put_new("display_url", preview_value(preview, :display_url))
          |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
          |> Map.new()
      })

    :ok
  end

  defp sanitize_preview_telemetry_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take([
      "x",
      "y",
      "button",
      "modifiers",
      "mode",
      "url",
      "key",
      "delta_x",
      "delta_y",
      "request_id",
      "status",
      "reason",
      "selector",
      "nth",
      "text_length",
      "iframe_src",
      "loaded_url",
      "loaded",
      "diagnostic",
      "load_ms",
      "recovery_attempts",
      "width",
      "height"
    ])
    |> sanitize_modifiers()
  end

  defp sanitize_preview_telemetry_metadata(_), do: %{}

  defp sanitize_modifiers(%{"modifiers" => modifiers} = metadata) when is_map(modifiers) do
    Map.put(metadata, "modifiers", Map.take(modifiers, ["alt", "ctrl", "meta", "shift"]))
  end

  defp sanitize_modifiers(metadata), do: metadata

  defp preview_activity_summary(event, metadata) do
    case to_string(event || "interaction") do
      "pointer_down" -> pointer_summary("pointer down", metadata)
      "pointer_up" -> pointer_summary("pointer up", metadata)
      "snapshot_click" -> pointer_summary("snapshot click", metadata)
      "key_intent" -> "key intent: " <> to_string(Map.get(metadata, "key", "unknown"))
      "iframe_loaded" -> "iframe loaded"
      "iframe_error" -> "iframe error"
      "iframe_load_timeout" -> "iframe load timeout"
      "iframe_focus" -> "iframe focused"
      "iframe_blur" -> "iframe blurred"
      "preview_reopen_requested" -> "preview reopen requested"
      "visibility_heartbeat" -> "visibility heartbeat"
      "overlay_destroyed" -> "preview overlay destroyed"
      "recover" -> "recover preview pane"
      "scroll" -> "scroll"
      "selected" -> "selected preview pane"
      "exited" -> "exited preview pane"
      other -> other
    end
  end

  defp pointer_summary(label, metadata) when is_map(metadata) do
    case {Map.get(metadata, "x"), Map.get(metadata, "y")} do
      {x, y} when is_integer(x) and is_integer(y) -> "#{label} @ #{x},#{y}"
      _ -> label
    end
  end

  defp preview_value(nil, _key), do: nil

  defp preview_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp preview_value(_value, _key), do: nil

  # Legacy event-name → generic pane:input translation. Routing through
  # FilePaneEvents keeps a single authorization path (Panes.get_by_pane +
  # workspace-alias match); a refused/unknown pane surfaces as the legacy
  # flash instead of the silent JS reply.
  defp legacy_preview_input(socket, params, type) do
    case CaseinWeb.WorkspaceLive.Show.FilePaneEvents.handle_event(
           "pane:input",
           Map.put(params, "type", type),
           socket
         ) do
      {:reply, %{error: error}, socket} ->
        {:noreply, put_flash(socket, :error, "Preview control failed: #{error}")}

      other ->
        other
    end
  end

  @doc false
  # Generic pane:input dispatch for :preview panes. Called by FilePaneEvents
  # AFTER pane authorization. Mirrors the legacy preview-pane:* handlers
  # one-for-one; assign updates flow back through the registry's Panes.Events
  # broadcasts (apply_pane_event/2) rather than being rebuilt here.
  def dispatch_preview_input(socket, pane_id, %{"type" => "go_back"}),
    do: preview_history_input(socket, pane_id, :go_back)

  def dispatch_preview_input(socket, pane_id, %{"type" => "go_forward"}),
    do: preview_history_input(socket, pane_id, :go_forward)

  def dispatch_preview_input(socket, pane_id, %{"type" => "reload"}),
    do: preview_history_input(socket, pane_id, :reload)

  def dispatch_preview_input(socket, pane_id, %{"type" => "close"}) do
    record_preview_activity(socket, pane_id, "close", %{"source" => "header"})

    case Pane.impl(:preview).handle_input(pane_id, %{"type" => "close"}) do
      :ok ->
        # The registry's :removed pane event confirms asynchronously; drop the
        # pane eagerly so the overlay disappears on this render (legacy
        # behavior).
        {:noreply,
         socket
         |> assign(:preview_panes, Map.delete(socket.assigns[:preview_panes] || %{}, pane_id))
         |> assign(:feature_panes, Map.delete(socket.assigns[:feature_panes] || %{}, pane_id))
         |> maybe_clear_entered_preview_pane(pane_id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Preview close failed: #{inspect(reason)}")}
    end
  end

  # Recover is consciously preview-only: it kills the tmux pane and re-splits a
  # fresh preview using viewer context (actor id, terminal cwd, the viewer's
  # tmux session fallback), which the pane behaviour has no access to. It still
  # arrives through the generic pane:input route and authorization.
  def dispatch_preview_input(socket, pane_id, %{"type" => "recover"}) do
    record_preview_activity(socket, pane_id, "recover", %{"source" => "preview_status"})

    with %{url: url} = registration <- PreviewPanes.get_by_pane(pane_id),
         tmux_session when is_binary(tmux_session) and tmux_session != "" <-
           registration.tmux_session || socket.assigns[:tmux_session],
         _kill_result <- TerminalState.tmux_adapter().kill_pane(tmux_session, pane_id),
         :ok <- PreviewPanes.deregister(pane_id),
         {:ok, socket} <- split_workspace_preview(socket, url, %{}) do
      {:noreply,
       socket
       |> assign(:preview_panes, Map.delete(socket.assigns[:preview_panes] || %{}, pane_id))
       |> assign(:feature_panes, Map.delete(socket.assigns[:feature_panes] || %{}, pane_id))
       |> maybe_clear_entered_preview_pane(pane_id)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Preview pane not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Preview recover failed: #{inspect(reason)}")}

      reason ->
        {:noreply, put_flash(socket, :error, "Preview recover failed: #{inspect(reason)}")}
    end
  end

  def dispatch_preview_input(socket, _pane_id, _input),
    do: {:reply, %{error: "unsupported_input"}, socket}

  defp preview_history_input(socket, pane_id, action)
       when action in [:go_back, :go_forward, :reload] do
    record_preview_activity(socket, pane_id, to_string(action), %{"source" => "header"})

    case Pane.impl(:preview).handle_input(pane_id, %{"type" => Atom.to_string(action)}) do
      :ok ->
        # The updated registration arrives via the registry's :updated pane
        # event; force-reload here because a same-URL refresh must still reload
        # the iframe (the soft push only re-points src on a real URL change).
        {:noreply,
         socket
         |> assign(:entered_preview_pane_id, pane_id)
         |> push_event("casein:reload_preview_iframes", %{
           "pane_id" => pane_id,
           "force" => true
         })}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Preview control failed: #{inspect(reason)}")}
    end
  end

  defp maybe_clear_entered_preview_pane(socket, pane_id) do
    if socket.assigns[:entered_preview_pane_id] == pane_id do
      assign(socket, :entered_preview_pane_id, nil)
    else
      socket
    end
  end

  defp payload_value(payload, key) when is_map(payload) and is_atom(key) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end
end
