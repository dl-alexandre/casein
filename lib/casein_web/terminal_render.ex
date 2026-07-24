defmodule CaseinWeb.TerminalRender do
  @moduledoc """
  Builds the JSON-safe `ghostty:render` payload from a `Ghostty.Terminal`
  render state, with row-level diffing against the previously sent cells.

  This logic is shared between:

    * `CaseinWeb.WorkspaceLive.PaneWorker` — the per-pane process that drains
      its own PTY output and builds frames off the LiveView process, so heavy
      streaming output can't starve the LiveView channel; and
    * `CaseinWeb.GhosttyTerminalComponent` — the in-band path for input-driven
      refreshes (key/text/resize/ready) where building on the LiveView is fine
      because those are low-frequency, human-paced events.

  Keeping it in one module guarantees both paths produce byte-identical
  payloads, so the browser hook (`ghostty_terminal.js`) never has to care which
  process built the frame.
  """

  alias CaseinWeb.TerminalTelemetry

  @type cells :: list()
  @type payload :: map()

  @doc """
  Reads the current render state from `term` and builds a payload.

  Returns `{payload, cells}` where `cells` is the raw cell grid to retain as
  the next diff baseline, or `nil` if the term process is gone/unresponsive
  (the caller should skip the frame — a later flush will repaint).

  Options:

    * `:previous_cells` — the last cell grid sent (for row diffing); `nil`
      forces a full frame.
    * `:force_full?` — always send the full grid (used on first mount / resize).
    * `:frame_seq` / `:frame_epoch` — optional per-terminal sequencing metadata.
    * `:screen_mode` — `:normal` or `:alternate`, folded from the PTY stream by
      `Casein.Terminals.ScreenMode`. The client's layout branches on it: only a
      normal-screen pane may be row-pinned when the soft keyboard opens.
  """
  @spec frame_from_term(GenServer.server(), String.t(), keyword()) ::
          {payload(), cells()} | nil
  def frame_from_term(term, id, opts \\ []) do
    case render_state(term) do
      %{
        cells: cells,
        cursor: cursor,
        mouse: mouse,
        scrollbar: scrollbar,
        focus_reporting: focus_reporting
      } ->
        payload =
          build_payload(id, cells, cursor, mouse, scrollbar, focus_reporting, opts)

        {payload, cells}

      nil ->
        nil
    end
  end

  # Synchronous term GenServer calls block the calling process. Catch the exit
  # so a dead/crashed term degrades to "skip this frame" instead of crashing
  # the caller (a crashed LiveView makes the client reload the whole page).
  defp render_state(term) do
    if is_pid(term) and Process.alive?(term) do
      Ghostty.Terminal.render_state(term)
    else
      nil
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  Builds a payload from already-fetched render-state fields. Useful when the
  caller already has the cells in hand.
  """
  @spec build_payload(String.t(), cells(), map(), any(), any(), any(), keyword()) :: payload()
  def build_payload(id, cells, cursor, mouse, scrollbar, focus_reporting, opts) do
    started = System.monotonic_time()

    base = %{
      id: id,
      cursor: Map.update!(cursor, :color, &color_to_list/1),
      mouse: mouse,
      scrollbar: scrollbar,
      focus_reporting: focus_reporting,
      screen_mode: Keyword.get(opts, :screen_mode, :normal)
    }

    previous = Keyword.get(opts, :previous_cells)
    force_full? = Keyword.get(opts, :force_full?, false)

    {payload, full_frame?, changed_row_count} =
      if force_full? do
        {Map.put(base, :cells, cells_to_payload(cells)), true, length(cells)}
      else
        case changed_rows(previous, cells) do
          {:ok, rows} -> {Map.put(base, :rows, rows), false, length(rows)}
          :shape_changed -> {Map.put(base, :cells, cells_to_payload(cells)), true, length(cells)}
        end
      end

    payload
    |> Map.put(:full_frame, full_frame?)
    |> maybe_put_frame_sequence(opts)
    |> emit_frame_telemetry(id, cells, full_frame?, changed_row_count, started)
  end

  defp maybe_put_frame_sequence(payload, opts) do
    with {:ok, seq} <- Keyword.fetch(opts, :frame_seq),
         {:ok, epoch} <- Keyword.fetch(opts, :frame_epoch) do
      payload
      |> Map.put(:frame_seq, seq)
      |> Map.put(:frame_epoch, epoch)
    else
      :error -> payload
    end
  end

  defp emit_frame_telemetry(payload, id, cells, full_frame?, changed_row_count, started) do
    :telemetry.execute(
      [:casein, :terminal, :render_frame],
      %{
        count: 1,
        duration_us: TerminalTelemetry.duration_us(started),
        rows: length(cells),
        cells: TerminalTelemetry.cell_count(cells),
        changed_rows: changed_row_count
      }
      |> Map.merge(TerminalTelemetry.sampled_payload_measurements(payload)),
      %{
        id: id,
        full_frame?: full_frame?,
        sequenced?: Map.has_key?(payload, :frame_seq),
        empty_incremental?: not full_frame? and changed_row_count == 0
      }
    )

    payload
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
end
