defmodule Casein.Terminals.WebLinkScanner do
  @moduledoc """
  Pure per-row scanner for clickable http(s) URLs in rendered terminal rows
  (the `ghostty:render` frame hot path).

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

  Cost controls mirror the file scanner: a `:binary.match/2` gate on `"://"`
  rejects the overwhelming majority of rows (prompts, TUI chrome, dividers)
  before any regex runs, and at most eight links are taken per row.
  """

  alias Casein.Links.Scanner

  @max_links_per_row 8

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
    Enum.flat_map(rows, fn {index, text} ->
      text
      |> scan_row()
      |> Enum.map(&Map.put(&1, :row, index))
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
