defmodule Casein.Terminals.WebLinkScanner do
  @moduledoc """
  Pure scanner for clickable http(s) URLs in rendered terminal rows (the
  `ghostty:render` frame hot path).

  Sibling to `Casein.Terminals.FileLinkScanner`: that module linkifies
  workspace file paths (and deliberately *excludes* URL spans); this one does
  the opposite, surfacing web URLs so the client can open them in a new tab.
  Unlike file links, web links need no filesystem validation — an URL is its
  own target — so this scanner never touches disk and runs for remote sessions
  too.

  URL span detection is delegated to `Casein.Links.Scanner.scan_urls/1` (the
  shared, tested `https?://…` matcher with punctuation trimming). Its `Span`
  offsets are **byte** offsets; this module converts them to **cell columns**
  (`from`/`to`, zero-based, inclusive) so underline overlays can position
  directly from cell metrics — the same contract `FileLinkScanner` emits.

  Ghostty's rendered cell grid does not currently expose its soft-wrap marker.
  To keep long links usable, `scan_rows/1` conservatively joins a URL to
  immediately following rows only when its span reaches the rightmost cell.
  Every resulting row segment carries the complete URL, so clicking any part
  of a wrapped link opens the same destination.

  Cost controls mirror the file scanner: a `:binary.match/2` gate on `"://"`
  rejects the overwhelming majority of rows (prompts, TUI chrome, dividers)
  before any regex runs, at most eight links are taken per row, and wrapped
  reconstruction is capped at sixteen rows.
  """

  alias Casein.Links.Scanner

  @max_links_per_row 8
  @max_wrapped_rows 16

  @type link :: %{
          row: non_neg_integer(),
          from: non_neg_integer(),
          to: non_neg_integer(),
          url: String.t()
        }

  @doc """
  Scan indexed rows (`[{row_index, text}]`) and return web links tagged with
  their row: `[%{row, from, to, url}]`.
  """
  @spec scan_rows([{non_neg_integer(), String.t()}]) :: [link()]
  def scan_rows(rows) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {{index, text}, position} ->
      text
      |> scan_row()
      |> Enum.flat_map(&link_segments(rows, position, index, text, &1))
    end)
  end

  @doc """
  Scan one row of terminal text. Returns `[%{from, to, url}]` with `from`/`to`
  as zero-based inclusive cell columns.
  """
  @spec scan_row(String.t()) :: [
          %{from: non_neg_integer(), to: non_neg_integer(), url: String.t()}
        ]
  def scan_row(text) when is_binary(text) do
    # Cheap gate: every http(s) URL contains "://". Rows without it — nearly
    # all of them — never reach the regex.
    case :binary.match(text, "://") do
      :nomatch ->
        []

      _ ->
        text
        |> Scanner.scan_urls()
        |> Enum.take(@max_links_per_row)
        |> Enum.map(fn %Scanner.Span{col_start: start, col_end: stop, raw: raw} ->
          %{from: byte_to_col(text, start), to: byte_to_col(text, stop) - 1, url: raw}
        end)
    end
  end

  def scan_row(_text), do: []

  defp link_segments(rows, position, index, text, link) do
    if link.to == String.length(text) - 1 do
      extend_wrapped_link(rows, position, link) ||
        [Map.put(link, :row, index)]
    else
      [Map.put(link, :row, index)]
    end
  end

  defp extend_wrapped_link(rows, position, link) do
    wrapped_rows =
      rows
      |> Enum.drop(position)
      |> Enum.take(@max_wrapped_rows)
      |> take_contiguous_rows()

    joined = Enum.map_join(wrapped_rows, fn {_index, text} -> text end)

    with true <- safe_continuation?(wrapped_rows),
         %{to: stop, url: url} <-
           Enum.find(scan_row(joined), &(&1.from == link.from and &1.to > link.to)) do
      split_link(wrapped_rows, link.from, stop, url)
    else
      _ -> nil
    end
  end

  # A second scheme at column zero is overwhelmingly likely to be a new hard
  # line, not a URL continuation. Avoid joining two adjacent full-width URLs.
  defp safe_continuation?([_first, {_index, continuation} | _]) do
    continuation != "" and
      not starts_with_whitespace?(continuation) and
      not Regex.match?(~r/^https?:\/\//i, continuation)
  end

  defp safe_continuation?(_rows), do: false

  defp take_contiguous_rows([]), do: []

  defp take_contiguous_rows([first | rest]) do
    rest
    |> take_contiguous_rows([first])
    |> Enum.reverse()
  end

  defp take_contiguous_rows(
         [{index, _text} = row | rest],
         [{previous_index, previous_text} | _] = taken
       )
       when index == previous_index + 1 do
    if row_filled?(previous_text) do
      take_contiguous_rows(rest, [row | taken])
    else
      taken
    end
  end

  defp take_contiguous_rows(_rest, taken), do: taken

  defp split_link(rows, start, stop, url) do
    {_offset, segments} =
      Enum.reduce_while(rows, {0, []}, fn {row, text}, {offset, segments} ->
        width = String.length(text)
        row_start = max(start - offset, 0)
        row_stop = min(stop - offset, width - 1)

        if row_stop < 0 do
          {:cont, {offset + width, segments}}
        else
          segment = %{row: row, from: row_start, to: row_stop, url: url}
          next = {offset + width, [segment | segments]}

          if stop < offset + width, do: {:halt, next}, else: {:cont, next}
        end
      end)

    Enum.reverse(segments)
  end

  defp row_filled?(text), do: text != "" and not ends_with_whitespace?(text)

  defp starts_with_whitespace?(text),
    do: Regex.match?(~r/^\s/u, text)

  defp ends_with_whitespace?(text),
    do: Regex.match?(~r/\s$/u, text)

  # Cell columns == byte offsets on all-ASCII rows (the common case). Rows
  # carrying multi-byte glyphs convert via a grapheme count of the byte
  # prefix — the row text is built one grapheme per cell (see
  # FileLinkScanner.row_text/1), so grapheme index is the column.
  defp byte_to_col(text, byte_offset) do
    if byte_size(text) == String.length(text) do
      byte_offset
    else
      text |> binary_part(0, byte_offset) |> String.length()
    end
  end
end
