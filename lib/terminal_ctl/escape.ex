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

  defp last_cursor_report(data) do
    case @cursor_report |> Regex.scan(data, capture: :all_but_first) |> List.last() do
      [row_s, col_s] ->
        %{row: String.to_integer(row_s), col: String.to_integer(col_s), pending: false}

      _ ->
        nil
    end
  end
end
