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
      <textarea data-ghostty-input="true" autofocus={@autofocus} aria-label="Terminal input"></textarea>
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
    if Ghostty.Terminal.focus_reporting?(socket.assigns.term) do
      case Ghostty.LiveTerminal.handle_focus(focused) do
        {:ok, data} -> write_data(socket, data)
        :none -> :ok
      end
    end

    {:noreply, push_render(socket)}
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

  defp push_render(socket, opts \\ []) do
    term = socket.assigns.term

    if is_pid(term) and Process.alive?(term) do
      %{
        cells: cells,
        cursor: cursor,
        mouse: mouse,
        scrollbar: scrollbar,
        focus_reporting: focus_reporting
      } =
        Ghostty.Terminal.render_state(term)

      payload =
        render_payload(socket.assigns.id, cells, cursor, mouse, scrollbar, focus_reporting,
          previous_cells: socket.assigns[:last_render_cells],
          force_full?: Keyword.get(opts, :force_full?, false)
        )

      socket
      |> assign(:last_render_cells, cells)
      |> Phoenix.LiveView.push_event("ghostty:render", payload)
    else
      socket
    end
  end

  defp render_payload(id, cells, cursor, mouse, scrollbar, focus_reporting, opts) do
    base = %{
      id: id,
      cursor: cursor |> Map.update!(:color, &color_to_list/1),
      mouse: mouse,
      scrollbar: scrollbar,
      focus_reporting: focus_reporting
    }

    previous = Keyword.get(opts, :previous_cells)

    if Keyword.get(opts, :force_full?, false) do
      Map.put(base, :cells, cells_to_payload(cells))
    else
      case changed_rows(previous, cells) do
        {:ok, rows} -> Map.put(base, :rows, rows)
        :shape_changed -> Map.put(base, :cells, cells_to_payload(cells))
      end
    end
  end

  defp changed_rows(previous, cells) when is_list(previous) and is_list(cells),
    do: do_changed_rows(previous, cells, 0, [])

  defp changed_rows(_previous, _cells), do: :shape_changed

  defp do_changed_rows([], [], _index, acc), do: {:ok, Enum.reverse(acc)}

  defp do_changed_rows([prev_row | prev_rest], [row | rest], index, acc)
       when is_list(prev_row) and is_list(row) do
    cond do
      prev_row == row ->
        do_changed_rows(prev_rest, rest, index + 1, acc)

      same_row_shape?(prev_row, row) ->
        changed_row = %{index: index, cells: row_to_payload(row)}
        do_changed_rows(prev_rest, rest, index + 1, [changed_row | acc])

      true ->
        :shape_changed
    end
  end

  defp do_changed_rows(_previous, _cells, _index, _acc), do: :shape_changed

  defp same_row_shape?([], []), do: true
  defp same_row_shape?([_ | prev_rest], [_ | rest]), do: same_row_shape?(prev_rest, rest)
  defp same_row_shape?(_prev_row, _row), do: false

  defp color_to_list(nil), do: nil
  defp color_to_list({r, g, b}), do: [r, g, b]

  defp cells_to_payload(cells) do
    Enum.map(cells, &row_to_payload/1)
  end

  defp row_to_payload(row) when is_list(row) do
    Enum.map(row, fn {char, fg, bg, flags} ->
      [char, color_to_list(fg), color_to_list(bg), flags]
    end)
  end

  defp parse_dimension!(value) when is_integer(value) and value > 0, do: value

  defp parse_dimension!(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> raise ArgumentError, "invalid terminal dimension: #{inspect(value)}"
    end
  end
end
