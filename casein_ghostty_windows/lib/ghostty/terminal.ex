defmodule Ghostty.Terminal do
  @moduledoc "Stateful VT screen model for native Windows releases."

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
    cols = max(Keyword.get(opts, :cols, 80), 1)
    rows = max(Keyword.get(opts, :rows, 24), 1)

    {:ok,
     %{
       cols: cols,
       rows: rows,
       max_scrollback: Keyword.get(opts, :max_scrollback, 5_000),
       owner: Keyword.get(opts, :owner, self()),
       screen: blank_screen(cols, rows),
       scrollback: [],
       offset: 0,
       cursor_x: 0,
       cursor_y: 0,
       wrap_pending: false,
       saved_cursor: {0, 0},
       pending: ""
     }}
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    {state, pending} = consume(state, state.pending <> data)
    {:reply, :ok, %{state | pending: pending, offset: 0}}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    cols = max(cols, 1)
    rows = max(rows, 1)
    screen = resize_screen(state.screen, cols, rows)

    {:reply, :ok,
     %{
       state
       | cols: cols,
         rows: rows,
         screen: screen,
         cursor_x: min(state.cursor_x, cols - 1),
         cursor_y: min(state.cursor_y, rows - 1),
         wrap_pending: false
     }}
  end

  def handle_call(:reset, _from, state), do: {:reply, :ok, clear_screen(state)}

  def handle_call({:scroll, delta}, _from, state) do
    max_offset = length(state.scrollback)
    {:reply, :ok, %{state | offset: (state.offset - delta) |> max(0) |> min(max_offset)}}
  end

  def handle_call({:snapshot, format}, _from, state) when format in [:plain, :vt] do
    text = (state.scrollback ++ state.screen) |> Enum.map(&row_text/1) |> Enum.join("\n")
    {:reply, {:ok, text}, state}
  end

  def handle_call({:snapshot, :html}, _from, state) do
    {:ok, text} = snapshot_text(state)

    escaped =
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    {:reply, {:ok, "<pre>#{escaped}</pre>"}, state}
  end

  def handle_call(:focus_reporting, _from, state), do: {:reply, false, state}
  def handle_call(:render_state, _from, state), do: {:reply, render_state_from(state), state}

  defp snapshot_text(state) do
    {:ok, (state.scrollback ++ state.screen) |> Enum.map(&row_text/1) |> Enum.join("\n")}
  end

  defp render_state_from(state) do
    visible = visible_rows(state)

    %{
      cells: Enum.map(visible, &Enum.map(&1, fn char -> {char, nil, nil, 0} end)),
      cursor: %{
        x: state.cursor_x,
        y: if(state.offset == 0, do: state.cursor_y, else: state.rows - 1),
        visible: state.offset == 0,
        shape: :block,
        color: nil
      },
      mouse: %{},
      scrollbar: %{
        total: length(state.scrollback) + state.rows,
        len: state.rows,
        offset: state.offset
      },
      focus_reporting: false
    }
  end

  defp visible_rows(%{offset: 0} = state), do: state.screen

  defp visible_rows(state) do
    all = state.scrollback ++ state.screen
    ending = max(length(all) - state.offset, state.rows)
    Enum.slice(all, max(ending - state.rows, 0), state.rows)
  end

  defp consume(state, ""), do: {state, ""}

  defp consume(state, <<27, ?[, rest::binary>>) do
    case take_csi(rest) do
      :incomplete -> {state, <<27, ?[, rest::binary>>}
      {params, final, tail} -> consume(apply_csi(state, params, final), tail)
    end
  end

  defp consume(state, <<27, ?], rest::binary>>) do
    case take_osc(rest) do
      :incomplete -> {state, <<27, ?], rest::binary>>}
      tail -> consume(state, tail)
    end
  end

  defp consume(state, <<27>>), do: {state, <<27>>}
  defp consume(state, <<27, _escape, rest::binary>>), do: consume(state, rest)

  defp consume(state, <<?\r, rest::binary>>),
    do: consume(%{state | cursor_x: 0, wrap_pending: false}, rest)

  defp consume(state, <<?\n, rest::binary>>), do: consume(linefeed(state), rest)

  defp consume(state, <<?\b, rest::binary>>),
    do:
      consume(
        %{state | cursor_x: max(state.cursor_x - 1, 0), wrap_pending: false},
        rest
      )

  defp consume(state, <<?\t, rest::binary>>) do
    next_stop = min((div(state.cursor_x, 8) + 1) * 8, state.cols - 1)
    consume(%{state | cursor_x: next_stop, wrap_pending: false}, rest)
  end

  defp consume(state, <<control, rest::binary>>) when control < 32,
    do: consume(state, rest)

  defp consume(state, data) do
    case String.next_grapheme(data) do
      {grapheme, rest} -> consume(put_grapheme(state, grapheme), rest)
      nil -> {state, ""}
    end
  rescue
    ArgumentError -> {state, data}
  end

  defp take_csi(data), do: take_csi(data, "")
  defp take_csi("", _params), do: :incomplete

  defp take_csi(<<byte, rest::binary>>, params) when byte >= 0x40 and byte <= 0x7E,
    do: {params, byte, rest}

  defp take_csi(<<byte, rest::binary>>, params), do: take_csi(rest, params <> <<byte>>)

  defp take_osc(data) do
    case :binary.match(data, [<<7>>, <<27, ?\\>>]) do
      :nomatch -> :incomplete
      {index, length} -> binary_part(data, index + length, byte_size(data) - index - length)
    end
  end

  defp apply_csi(state, params, final) do
    private? = String.starts_with?(params, "?")
    values = csi_values(String.trim_leading(params, "?"))
    first = max(List.first(values) || 1, 1)

    result =
      case final do
        ?A -> %{state | cursor_y: max(state.cursor_y - first, 0)}
        ?B -> %{state | cursor_y: min(state.cursor_y + first, state.rows - 1)}
        ?C -> %{state | cursor_x: min(state.cursor_x + first, state.cols - 1)}
        ?D -> %{state | cursor_x: max(state.cursor_x - first, 0)}
        ?E -> %{state | cursor_x: 0, cursor_y: min(state.cursor_y + first, state.rows - 1)}
        ?F -> %{state | cursor_x: 0, cursor_y: max(state.cursor_y - first, 0)}
        ?G -> %{state | cursor_x: min(first - 1, state.cols - 1)}
        ?d -> %{state | cursor_y: min(first - 1, state.rows - 1)}
        ?H -> position_cursor(state, values)
        ?f -> position_cursor(state, values)
        ?J -> erase_display(state, List.first(values) || 0)
        ?K -> erase_line(state, List.first(values) || 0)
        ?s -> %{state | saved_cursor: {state.cursor_x, state.cursor_y}}
        ?u -> restore_cursor(state)
        ?n -> reply_to_status_query(state, values)
        ?c -> reply_to_device_attributes(state)
        ?h -> if private? and Enum.member?(values, 1049), do: clear_screen(state), else: state
        ?l -> if private? and Enum.member?(values, 1049), do: clear_screen(state), else: state
        _ -> state
      end

    %{result | wrap_pending: false}
  end

  defp csi_values(""), do: []

  defp csi_values(params) do
    params
    |> String.split(";")
    |> Enum.map(fn value ->
      case Integer.parse(value) do
        {integer, _} -> integer
        :error -> 0
      end
    end)
  end

  defp position_cursor(state, values) do
    row = max(Enum.at(values, 0, 1), 1) - 1
    col = max(Enum.at(values, 1, 1), 1) - 1
    %{state | cursor_x: min(col, state.cols - 1), cursor_y: min(row, state.rows - 1)}
  end

  defp restore_cursor(state) do
    {x, y} = state.saved_cursor
    %{state | cursor_x: min(x, state.cols - 1), cursor_y: min(y, state.rows - 1)}
  end

  defp reply_to_status_query(state, values) do
    case List.first(values) do
      5 -> send(state.owner, {:pty_write, "\e[0n"})
      6 -> send(state.owner, {:pty_write, "\e[#{state.cursor_y + 1};#{state.cursor_x + 1}R"})
      _ -> :ok
    end

    state
  end

  defp reply_to_device_attributes(state) do
    send(state.owner, {:pty_write, "\e[?1;2c"})
    state
  end

  defp erase_display(state, 2), do: clear_screen(state)
  defp erase_display(state, 3), do: %{clear_screen(state) | scrollback: []}

  defp erase_display(state, 0) do
    row = Enum.at(state.screen, state.cursor_y) |> blank_range(state.cursor_x, state.cols - 1)
    screen = List.replace_at(state.screen, state.cursor_y, row)

    screen =
      if state.cursor_y < state.rows - 1 do
        Enum.with_index(screen)
        |> Enum.map(fn {line, index} ->
          if index > state.cursor_y, do: blank_row(state.cols), else: line
        end)
      else
        screen
      end

    %{state | screen: screen}
  end

  defp erase_display(state, _), do: state

  defp erase_line(state, mode) do
    {from, to} =
      case mode do
        1 -> {0, state.cursor_x}
        2 -> {0, state.cols - 1}
        _ -> {state.cursor_x, state.cols - 1}
      end

    row = Enum.at(state.screen, state.cursor_y) |> blank_range(from, to)
    %{state | screen: List.replace_at(state.screen, state.cursor_y, row)}
  end

  defp blank_range(row, from, to) do
    Enum.with_index(row)
    |> Enum.map(fn {char, index} -> if index >= from and index <= to, do: "", else: char end)
  end

  defp put_grapheme(state, grapheme) do
    state =
      if state.wrap_pending do
        state |> Map.put(:cursor_x, 0) |> Map.put(:wrap_pending, false) |> linefeed()
      else
        state
      end

    row = Enum.at(state.screen, state.cursor_y) |> List.replace_at(state.cursor_x, grapheme)
    state = %{state | screen: List.replace_at(state.screen, state.cursor_y, row)}

    if state.cursor_x == state.cols - 1 do
      %{state | wrap_pending: true}
    else
      %{state | cursor_x: state.cursor_x + 1}
    end
  end

  defp linefeed(%{cursor_y: cursor_y, rows: rows} = state) when cursor_y < rows - 1,
    do: %{state | cursor_y: cursor_y + 1, wrap_pending: false}

  defp linefeed(state) do
    [top | rest] = state.screen
    scrollback = Enum.take(state.scrollback ++ [top], -state.max_scrollback)

    %{
      state
      | screen: rest ++ [blank_row(state.cols)],
        scrollback: scrollback,
        wrap_pending: false
    }
  end

  defp clear_screen(state) do
    %{
      state
      | screen: blank_screen(state.cols, state.rows),
        cursor_x: 0,
        cursor_y: 0,
        wrap_pending: false,
        offset: 0
    }
  end

  defp resize_screen(screen, cols, rows) do
    resized = Enum.map(screen, &resize_row(&1, cols)) |> Enum.take(rows)
    resized ++ List.duplicate(blank_row(cols), max(rows - length(resized), 0))
  end

  defp resize_row(row, cols),
    do: Enum.take(row, cols) ++ List.duplicate("", max(cols - length(row), 0))

  defp blank_screen(cols, rows), do: List.duplicate(blank_row(cols), rows)
  defp blank_row(cols), do: List.duplicate("", cols)
  defp row_text(row), do: row |> Enum.join() |> String.trim_trailing()
end
