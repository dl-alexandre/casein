defmodule Ghostty.Terminal do
  @moduledoc "Minimal pure-Elixir terminal model for native Windows releases."

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def write(term, data), do: GenServer.call(term, {:write, IO.iodata_to_binary(data)})
  def resize(term, cols, rows), do: GenServer.call(term, {:resize, cols, rows})
  def reset(term), do: GenServer.call(term, :reset)
  def scroll(term, delta), do: GenServer.call(term, {:scroll, delta})
  def snapshot(term, format \\ :plain), do: GenServer.call(term, {:snapshot, format})
  def render_state(term), do: GenServer.call(term, :render_state)
  def focus_reporting?(term), do: GenServer.call(term, :focus_reporting)

  @impl true
  def init(opts) do
    {:ok,
     %{
       cols: Keyword.get(opts, :cols, 80),
       rows: Keyword.get(opts, :rows, 24),
       max_scrollback: Keyword.get(opts, :max_scrollback, 5_000),
       lines: [""],
       offset: 0
     }}
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    lines = append_text(state.lines, sanitize(data), state.max_scrollback)
    {:reply, :ok, %{state | lines: lines, offset: 0}}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    {:reply, :ok, %{state | cols: max(cols, 1), rows: max(rows, 1)}}
  end

  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | lines: [""], offset: 0}}

  def handle_call({:scroll, delta}, _from, state) do
    max_offset = max(length(state.lines) - state.rows, 0)
    {:reply, :ok, %{state | offset: (state.offset - delta) |> max(0) |> min(max_offset)}}
  end

  def handle_call({:snapshot, format}, _from, state) when format in [:plain, :vt] do
    {:reply, {:ok, Enum.join(state.lines, "\n")}, state}
  end

  def handle_call({:snapshot, :html}, _from, state) do
    escaped =
      state.lines
      |> Enum.join("\n")
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    {:reply, {:ok, "<pre>#{escaped}</pre>"}, state}
  end

  def handle_call(:focus_reporting, _from, state), do: {:reply, false, state}
  def handle_call(:render_state, _from, state), do: {:reply, render_state_from(state), state}

  defp render_state_from(state) do
    visible =
      state.lines |> visible_lines(state.rows, state.offset) |> Enum.map(&row(&1, state.cols))

    visible = visible ++ List.duplicate(row("", state.cols), max(state.rows - length(visible), 0))
    cursor_line = List.last(state.lines) || ""

    %{
      cells: visible,
      cursor: %{
        x: min(String.length(cursor_line), state.cols - 1),
        y: min(length(visible) - 1, state.rows - 1),
        visible: true,
        shape: :block,
        color: nil
      },
      mouse: %{},
      scrollbar: %{total: length(state.lines), len: state.rows, offset: state.offset},
      focus_reporting: false
    }
  end

  defp append_text(lines, data, max_lines) do
    [current | prior] = Enum.reverse(lines)
    parts = String.split(data, ~r/\r\n|\n|\r/)
    [first | rest] = parts
    updated = Enum.reverse(prior) ++ [current <> first] ++ rest
    Enum.take(updated, -max_lines)
  end

  defp visible_lines(lines, rows, offset) do
    end_index = max(length(lines) - offset, 0)
    start_index = max(end_index - rows, 0)
    Enum.slice(lines, start_index, rows)
  end

  defp row(text, cols) do
    cells = text |> String.graphemes() |> Enum.take(cols) |> Enum.map(&{&1, nil, nil, 0})
    cells ++ List.duplicate({"", nil, nil, 0}, max(cols - length(cells), 0))
  end

  defp sanitize(data) do
    data
    |> String.replace(~r/\e\][^\a]*(?:\a|\e\\)/, "")
    |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/, "")
  end
end
