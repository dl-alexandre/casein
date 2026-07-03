defmodule TerminalCtl.Escape do
  @moduledoc """
  Strip terminal control handshakes from PTY byte streams.

  Cursor reports, XTVERSION probes, and device-attribute queries are removed
  so they never enter replay buffers or reach raw subscribers as literal input.
  """

  @cursor_report ~r/\e\[\??(\d+);(\d+)R/
  @xtversion_query ~r/\e\[>[0-9;]*q/
  @xtversion_response ~r/\eP>\|[^\e]*(?:\e\\)/
  @device_attrs_query_or_response ~r/\e\[(?:\?|>)?[0-9;]*c/

  # Query forms ONLY (`?` payload). Set-forms (`\e]11;#112233\a`) and replies
  # carry real colors and must survive both replay and live paths.
  @osc_color_query ~r/\e\](?:10|11|12);\?(?:\a|\e\\)/
  @osc_palette_query ~r/\e\]4;\d{1,3};\?(?:;\d{1,3};\?)*(?:\a|\e\\)/

  @type cursor :: %{row: pos_integer(), col: pos_integer(), pending: false}

  @doc "Returns `{clean_data, cursor_report_or_nil}`."
  @spec strip_handshakes(binary()) :: {binary(), cursor() | nil}
  def strip_handshakes(data) when is_binary(data) do
    if :binary.match(data, "\e") == :nomatch do
      {data, nil}
    else
      clean =
        data
        |> then(&Regex.replace(@cursor_report, &1, ""))
        |> then(&Regex.replace(@xtversion_query, &1, ""))
        |> then(&Regex.replace(@xtversion_response, &1, ""))
        |> then(&Regex.replace(@device_attrs_query_or_response, &1, ""))

      {clean, last_cursor_report(data)}
    end
  end

  @doc """
  Strips OSC 10/11/12 color queries and OSC 4 palette queries (`?`-payload
  forms only) from a replay buffer.

  Replay-only by design: a stale query retained in the buffer would make every
  freshly attached viewer's emulator answer it again, injecting duplicate
  responses into the shared PTY. On the live path queries MUST pass through so
  the single elected responder can answer them — never apply this there.
  Set-forms (e.g. `\\e]11;#112233\\a`) are theme updates, not queries, and are
  always preserved.
  """
  @spec strip_color_queries(binary()) :: binary()
  def strip_color_queries(data) when is_binary(data) do
    if :binary.match(data, "\e]") == :nomatch do
      data
    else
      data
      |> then(&Regex.replace(@osc_color_query, &1, ""))
      |> then(&Regex.replace(@osc_palette_query, &1, ""))
    end
  end

  defp last_cursor_report(data) do
    case @cursor_report |> Regex.scan(data, capture: :all_but_first) |> List.last() do
      [row_s, col_s] ->
        %{row: String.to_integer(row_s), col: String.to_integer(col_s), pending: false}

      _ ->
        nil
    end
  end
end
