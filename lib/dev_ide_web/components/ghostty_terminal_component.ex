defmodule DevIdeWeb.GhosttyTerminalComponent do
  @moduledoc """
  DevIDE wrapper for Ghostty's LiveTerminal component.

  It keeps the public event contract from `Ghostty.LiveTerminal.Component`, but
  pushes row-diff render payloads after the first full frame to reduce LiveView
  event size for active terminals.
  """
  use Phoenix.LiveComponent

  @impl true
  def update(assigns, socket) do
    first_mount? = not Map.has_key?(socket.assigns, :term)
    themes_changed? = Map.get(assigns, :terminal_themes) != socket.assigns[:terminal_themes]
    force_full_refresh? =
      Map.get(assigns, :force_full_refresh, socket.assigns[:force_full_refresh]) == true

    # A swapped term process (e.g. the pane-history modal reopened on the same
    # pane before its previous worker fully wound down) invalidates every cell
    # the client holds — repaint from the new term or the viewer keeps showing
    # the dead one's last frame.
    term_changed? =
      not first_mount? and Map.has_key?(assigns, :term) and
        assigns.term != socket.assigns.term

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:pty, fn -> nil end)
      |> assign_new(:cols, fn -> 80 end)
      |> assign_new(:rows, fn -> 24 end)
      |> assign_new(:fit, fn -> false end)
      |> assign_new(:autofocus, fn -> false end)
      |> assign_new(:class, fn -> "" end)
      |> assign_new(:last_render_cells, fn -> nil end)
      |> assign_new(:terminal_themes, fn -> nil end)
      |> assign_new(:render_authority, fn -> :component end)
      |> assign_new(:read_only, fn -> false end)
      |> assign_new(:input_refresh_delay, fn -> nil end)
      |> assign_new(:force_full_refresh, fn -> false end)

    socket =
      cond do
        first_mount? or term_changed? or assigns[:refresh] ->
          socket =
            if term_changed? or force_full_refresh?,
              do: assign(socket, :last_render_cells, nil),
              else: socket

          socket
          |> push_terminal_theme()
          |> maybe_push_component_render(
            force_full?:
              first_mount? or term_changed? or force_full_refresh? or worker_render_authority?(socket),
            reason:
              cond do
                first_mount? -> :mount
                term_changed? -> :term_changed
                true -> :refresh
              end
          )

        themes_changed? ->
          push_terminal_theme(socket)

        true ->
          socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={["relative h-full w-full", @class]}
      phx-hook="GhosttyTerminal"
      phx-update="ignore"
      phx-target={@myself}
      data-cols={@cols}
      data-rows={@rows}
      data-fit={to_string(@fit)}
      data-autofocus={to_string(@autofocus)}
      data-render-authority={to_string(@render_authority)}
      style="font-family: monospace; line-height: 1.2;"
    >
      <textarea data-ghostty-input="true" aria-label="Terminal input"></textarea>
    </div>
    """
  end

  @impl true
  # Read-only viewers (the pane history modal) surface a seeded emulator whose
  # content must stay exactly what was captured: swallow anything that would
  # write into the term or PTY. Scroll/refresh/ready still flow — those only
  # move or repaint the viewport.
  def handle_event(event, _params, %{assigns: %{read_only: true}} = socket)
      when event in ["key", "text", "mouse"] do
    {:noreply, socket}
  end

  def handle_event("key", params, socket) do
    case Ghostty.LiveTerminal.handle_key(socket.assigns.term, params) do
      {:ok, data} -> write_data(socket, data)
      :none -> :ok
    end

    {:noreply, maybe_push_component_render(socket)}
  end

  @impl true
  def handle_event("text", %{"data" => data}, socket) when is_binary(data) do
    if data != "" do
      if socket.assigns.pty do
        write_data(socket, data)
      else
        Ghostty.LiveTerminal.handle_text(socket.assigns.term, data)
      end
    end

    {:noreply, maybe_push_component_render(socket)}
  end

  @impl true
  def handle_event("mouse", params, socket) do
    case Ghostty.LiveTerminal.handle_mouse(socket.assigns.term, params) do
      {:ok, data} -> write_data(socket, data)
      :none -> :ok
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("ready", %{"cols" => cols, "rows" => rows}, socket) do
    cols = parse_dimension!(cols)
    rows = parse_dimension!(rows)

    Ghostty.Terminal.resize(socket.assigns.term, cols, rows)
    send(self(), {:terminal_ready, socket.assigns.id, cols, rows})

    socket =
      socket
      |> assign(cols: cols, rows: rows)
      |> assign(:last_render_cells, nil)

    {:noreply, maybe_push_dimension_render(socket)}
  end

  @impl true
  def handle_event("resize", %{"cols" => cols, "rows" => rows}, socket) do
    cols = parse_dimension!(cols)
    rows = parse_dimension!(rows)

    # Resize only this viewer's local grid here — deliberately NOT the pty.
    # The shared PTY/tmux size is applied by the host LiveView via
    # PaneWorker.resize → SessionOwner, which tags the resize with the viewer
    # and applies the focused-viewer size policy. Passing the pty here resized
    # the shared PTY verbatim on ANY viewer's ResizeObserver event, so a
    # background or headless viewer condensed the focused operator's terminal
    # — and the owner's applied_size went stale, suppressing the corrective
    # policy resize until a viewer's size genuinely changed.
    Ghostty.LiveTerminal.handle_resize(socket.assigns.term, cols, rows)
    send(self(), {:terminal_resize, socket.assigns.id, cols, rows})

    socket =
      socket
      |> assign(cols: cols, rows: rows)
      |> assign(:last_render_cells, nil)

    {:noreply, maybe_push_dimension_render(socket)}
  end

  @impl true
  def handle_event("focus", %{"focused" => focused}, socket) do
    # Focus events fire on every click (the hidden input is focused on
    # mouseup). On a terminal that is actively streaming, the LiveView process
    # is already busy draining {:pty_flush, ...} with synchronous
    # `Ghostty.Terminal.write` calls. Adding a synchronous `focus_reporting?`
    # + a full `render_state` re-render here can stack past the channel
    # timeout window, which makes the LiveView client give up and
    # `reloadWithJitter` (looks like the page randomly refreshing on click).
    #
    # So: only touch the term when focus reporting is actually enabled, guard
    # that call, and skip the redundant re-render — the 16ms PTY flush loop
    # already repaints. The terminal does not need a fresh frame just because
    # focus moved.
    if call_term(socket.assigns.term, &Ghostty.Terminal.focus_reporting?/1, false) do
      case Ghostty.LiveTerminal.handle_focus(focused) do
        {:ok, data} -> write_data(socket, data)
        :none -> :ok
      end
    end

    {:noreply, socket}
  end

  @impl true
  # The client reports whether this viewer's tab is active (visible + window
  # focused). Forward it to the parent LiveView → PaneWorker → SessionOwner so the
  # shared PTY/tmux is sized to the focused viewer through the terminal owner.
  # No term work or re-render: this only influences the shared size, not this
  # viewer's own grid, which the 16ms PTY flush loop already repaints.
  def handle_event("viewport_active", %{"active" => active}, socket) do
    send(self(), {:terminal_active, socket.assigns.id, active == true})
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", params, socket) do
    force_full? = force_full_refresh?(params)

    if worker_render_authority?(socket) do
      notify_resync(socket, refresh_reason(params))
      {:noreply, socket}
    else
      socket =
        if force_full? do
          assign(socket, :last_render_cells, nil)
        else
          socket
        end

      {:noreply, push_render(socket, force_full?: force_full?)}
    end
  end

  @impl true
  def handle_event("scroll", %{"delta" => delta}, socket) do
    delta = parse_scroll_delta!(delta)

    if delta != 0 do
      call_term(socket.assigns.term, fn term -> Ghostty.Terminal.scroll(term, delta) end, :ok)
    end

    if worker_render_authority?(socket) do
      notify_resync(socket, :scroll)
      {:noreply, socket}
    else
      {:noreply, push_render(socket)}
    end
  end

  defp write_data(socket, data) do
    if socket.assigns.pty do
      Ghostty.PTY.write(socket.assigns.pty, data)
      maybe_schedule_input_refresh(socket)
    else
      Ghostty.Terminal.write(socket.assigns.term, data)
    end
  end

  defp maybe_schedule_input_refresh(%{assigns: %{input_refresh_delay: delay, id: id}})
       when is_integer(delay) and delay >= 0 do
    Process.send_after(self(), {:terminal_input_refresh, id}, delay)
    :ok
  end

  defp maybe_schedule_input_refresh(_socket), do: :ok

  # Builds and pushes a frame for input-driven refreshes (key/text/resize/
  # ready/refresh). These are low-frequency, human-paced events, so building
  # on the LiveView process is fine. The high-frequency PTY *output* path does
  # NOT come through here — `PaneWorker` builds those frames off the LiveView
  # process and the LiveView only forwards them (see WorkspaceLive.Show
  # `{:pane_frame, ...}`), which is what keeps heavy streaming output from
  # starving the channel.
  defp push_terminal_theme(socket) do
    case socket.assigns[:terminal_themes] do
      themes when is_map(themes) ->
        Phoenix.LiveView.push_event(socket, "terminal:theme", themes)

      _ ->
        socket
    end
  end

  defp maybe_push_component_render(socket, opts \\ []) do
    if worker_render_authority?(socket) do
      if Keyword.get(opts, :force_full?, false) do
        notify_resync(socket, Keyword.get(opts, :reason, :force_full))
      end

      socket
    else
      push_render(socket, opts)
    end
  end

  defp maybe_push_dimension_render(socket) do
    if worker_render_authority?(socket) do
      socket
    else
      push_render(socket, force_full?: true)
    end
  end

  defp push_render(socket, opts \\ []) do
    opts =
      Keyword.put_new(opts, :previous_cells, socket.assigns[:last_render_cells])

    case DevIdeWeb.TerminalRender.frame_from_term(socket.assigns.term, socket.assigns.id, opts) do
      {payload, cells} ->
        socket
        |> assign(:last_render_cells, cells)
        |> Phoenix.LiveView.push_event("ghostty:render", payload)

      nil ->
        # Term gone/unresponsive — skip this frame rather than crash the LV.
        socket
    end
  end

  defp worker_render_authority?(socket),
    do: socket.assigns[:render_authority] in [:worker, "worker"]

  defp notify_resync(socket, reason) do
    send(self(), {:terminal_resync, socket.assigns.id, reason})
  end

  defp force_full_refresh?(%{"force_full" => true}), do: true
  defp force_full_refresh?(%{"force_full" => "true"}), do: true
  defp force_full_refresh?(%{force_full: true}), do: true
  defp force_full_refresh?(_params), do: false

  defp refresh_reason(%{"reason" => reason}) when is_binary(reason), do: reason
  defp refresh_reason(%{reason: reason}) when is_binary(reason), do: reason
  defp refresh_reason(_params), do: :refresh

  # Synchronous term GenServer calls run on the LiveView process. If the term
  # process is overloaded or has died, a call here would otherwise block or
  # crash the LiveView — and a stalled/crashed LiveView makes the client
  # `reloadWithJitter` (the page "refreshing" on a click). Catch the exit and
  # degrade to `default` so interactivity never takes the channel down.
  defp call_term(term, fun, default) when is_function(fun, 1) do
    fun.(term)
  catch
    :exit, _ -> default
  end

  defp parse_dimension!(value) when is_integer(value) and value > 0, do: value

  defp parse_dimension!(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> raise ArgumentError, "invalid terminal dimension: #{inspect(value)}"
    end
  end

  defp parse_scroll_delta!(value) when is_integer(value), do: clamp_scroll_delta(value)

  defp parse_scroll_delta!(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> clamp_scroll_delta(parsed)
      _ -> 0
    end
  end

  defp parse_scroll_delta!(_), do: 0

  defp clamp_scroll_delta(delta) when delta < -20, do: -20
  defp clamp_scroll_delta(delta) when delta > 20, do: 20
  defp clamp_scroll_delta(delta), do: delta
end
