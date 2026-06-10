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

    socket =
      if first_mount? or assigns[:refresh] do
        push_render(socket, force_full?: first_mount?)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={@class}
      phx-hook="GhosttyTerminal"
      phx-update="ignore"
      phx-target={@myself}
      data-cols={@cols}
      data-rows={@rows}
      data-fit={to_string(@fit)}
      data-autofocus={to_string(@autofocus)}
      style="font-family: monospace; line-height: 1.2;"
    >
      <textarea data-ghostty-input="true" aria-label="Terminal input"></textarea>
    </div>
    """
  end

  @impl true
  def handle_event("key", params, socket) do
    case Ghostty.LiveTerminal.handle_key(socket.assigns.term, params) do
      {:ok, data} -> write_data(socket, data)
      :none -> :ok
    end

    {:noreply, push_render(socket)}
  end

  @impl true
  def handle_event("text", %{"data" => data}, socket) when is_binary(data) do
    if data != "" do
      if socket.assigns.pty do
        Ghostty.PTY.write(socket.assigns.pty, data)
      else
        Ghostty.LiveTerminal.handle_text(socket.assigns.term, data)
      end
    end

    {:noreply, push_render(socket)}
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

    {:noreply,
     socket
     |> assign(cols: cols, rows: rows)
     |> assign(:last_render_cells, nil)
     |> push_render(force_full?: true)}
  end

  @impl true
  def handle_event("resize", %{"cols" => cols, "rows" => rows}, socket) do
    cols = parse_dimension!(cols)
    rows = parse_dimension!(rows)

    Ghostty.LiveTerminal.handle_resize(socket.assigns.term, cols, rows, socket.assigns.pty)

    {:noreply,
     socket
     |> assign(cols: cols, rows: rows)
     |> assign(:last_render_cells, nil)
     |> push_render(force_full?: true)}
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
  def handle_event("refresh", _params, socket) do
    {:noreply, push_render(socket)}
  end

  defp write_data(socket, data) do
    if socket.assigns.pty do
      Ghostty.PTY.write(socket.assigns.pty, data)
    else
      Ghostty.Terminal.write(socket.assigns.term, data)
    end
  end

  # Builds and pushes a frame for input-driven refreshes (key/text/resize/
  # ready/refresh). These are low-frequency, human-paced events, so building
  # on the LiveView process is fine. The high-frequency PTY *output* path does
  # NOT come through here — `PaneWorker` builds those frames off the LiveView
  # process and the LiveView only forwards them (see WorkspaceLive.Show
  # `{:pane_frame, ...}`), which is what keeps heavy streaming output from
  # starving the channel.
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
end
