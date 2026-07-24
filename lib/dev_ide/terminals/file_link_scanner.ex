defmodule Casein.Terminals.FileLinkScanner do
  @moduledoc """
  Pure per-row scanner for workspace file-path candidates in rendered
  terminal rows (the `ghostty:render` frame hot path).

  Unlike `Casein.Links.Scanner` — the permissive URL/path candidate scanner
  behind the workspace open API — this scanner runs inside
  `CaseinWeb.WorkspaceLive.PaneWorker`'s frame build, up to ~125 times/s per
  pane under load, so it is deliberately narrow and cheap:

    * a `:binary.match/2` gate rejects rows without `/` or `.` before any
      regex runs;
    * one pass of a single regex covers both alternatives: slash paths with
      an extension (`lib/foo.ex:12`, `./a/b.js`, `/abs/p.c:3:7`, Elixir
      stacktrace lines) and bare `name.ext[:line]` names restricted to a
      known-extension allowlist;
    * the path charset is strict ASCII (no `u` regex flag on purpose), so
      box-drawing divider glyphs (`│`, `─`, …) can never be part of a match —
      links cannot leak across tmux split seams;
    * trailing punctuation (`)`, `,`, quotes, a bare `.` or `:`, …) is
      excluded structurally: matches must end in the extension or the
      `:line[:col]` suffix;
    * at most eight candidates are taken per row.

  Results carry **cell columns** (`from`/`to`, zero-based, inclusive), not
  byte offsets: rows containing multi-byte glyphs get their match offsets
  converted, so underline overlays can position directly from cell metrics.

  Candidates are *plausible spans only* — no filesystem access happens here.
  Callers validate them with `Casein.FilePanes.LinkResolver`.
  """

  @max_candidates_per_row 8

  # Mirrors Casein.Links.Scanner's allowlist (kept local: that module does not
  # export it, and the two scanners evolve independently).
  @known_extensions ~w(
    astro bash c cjs cpp cs css cts eex erl ex exs go h heex hpp hrl html
    java js json jsx leex lock markdown md mjs mts php py rb rs sh sql svelte
    toml ts tsx txt vue yaml yml zsh
  )

  @known_ext_pattern Enum.map_join(
                       Enum.sort_by(@known_extensions, &byte_size/1, :desc),
                       "|",
                       &Regex.escape/1
                     )

  # One pass, three path alternatives + an optional :line[:col] suffix.
  #
  #   1. `/abs/p.c`, `./a/b.js`, `../x/y.ex` — anchored by a `/`, `./` or `../`
  #      prefix; any 1-8 word-char extension.
  #   2. `lib/foo.ex` — relative with at least one directory segment; any
  #      extension.
  #   3. `foo_test.exs` — bare file name, extension allowlist only.
  #
  # The lookbehind refuses matches glued to path/word characters, which is
  # what keeps URL innards (`example.com/x.ex` after `//`) and mid-token
  # fragments out. `:` is deliberately NOT in the lookbehind so grep-style
  # `path:12:content` chains can still linkify a path at content start.
  # No `u` flag: byte-oriented ASCII classes make multi-byte glyphs
  # (box-drawing dividers, arrows) hard boundaries.
  @link_regex ~r<
    (?<![\w./@+-])
    (
      \.{0,2}/(?:[\w.@+-]+/)*[\w.@+-]+\.\w{1,8}
      |
      (?:[\w.@+-]+/)+[\w.@+-]+\.\w{1,8}
      |
      [\w@+-][\w.@+-]*\.(?:#{@known_ext_pattern})(?!\.?\w)
    )
    (?::(\d+)(?::(\d+))?)?
  >x

  @type link :: %{
          from: non_neg_integer(),
          to: non_neg_integer(),
          path: String.t(),
          line: pos_integer() | nil
        }

  @doc """
  Scan indexed rows (`[{row_index, text}]`) and return candidates tagged with
  their row: `[%{row, from, to, path, line}]`.
  """
  @spec scan_rows([{non_neg_integer(), String.t()}]) :: [map()]
  def scan_rows(rows) when is_list(rows) do
    Enum.flat_map(rows, fn {index, text} ->
      text
      |> scan_row()
      |> Enum.map(&Map.put(&1, :row, index))
    end)
  end

  @doc """
  Scan one row of terminal text. Returns `[%{from, to, path, line}]` with
  `from`/`to` as zero-based inclusive cell columns.
  """
  @spec scan_row(String.t()) :: [link()]
  def scan_row(text) when is_binary(text) do
    # Cheap gate: every candidate contains a "." (extension) and most contain
    # a "/". Rows with neither — the common case for TUI chrome, prompts and
    # divider rows — never reach the regex.
    case :binary.match(text, [".", "/"]) do
      :nomatch -> []
      _ -> do_scan(text)
    end
  end

  def scan_row(_text), do: []

  @doc """
  Render one grid row (a list of `{char, fg, bg, flags}` cells) to scannable
  text: exactly one grapheme per cell, blanks for empty/spacer cells, so
  grapheme index == cell column.
  """
  @spec row_text(list()) :: String.t()
  def row_text(cells) when is_list(cells) do
    cells
    |> Enum.map(&cell_char/1)
    |> IO.iodata_to_binary()
  end

  def row_text(_cells), do: ""

  defp cell_char({char, _fg, _bg, _flags}) when is_binary(char) and char != "", do: char
  defp cell_char([char | _rest]) when is_binary(char) and char != "", do: char
  defp cell_char(_cell), do: " "

  defp do_scan(text) do
    url_ranges = url_ranges(text)

    @link_regex
    |> Regex.scan(text, return: :index)
    |> Enum.reject(fn [{start, len} | _] ->
      overlaps_url?(start, len, url_ranges) or abuts_box_drawing?(text, start, len)
    end)
    |> Enum.take(@max_candidates_per_row)
    |> Enum.map(&build_link(text, &1))
  end

  # URL innards ("localhost:4000/assets/app.js") look like slash paths once
  # the scheme is out of frame. Rows carrying "://" get their URL spans
  # computed once and overlapping candidates dropped (same approach as
  # Casein.Links.Scanner). Byte ranges — compared before column conversion.
  @url_regex ~r{[a-z][a-z0-9+.-]*://[^\s"'<>]+}
  defp url_ranges(text) do
    case :binary.match(text, "://") do
      :nomatch ->
        []

      _ ->
        @url_regex
        |> Regex.scan(text, return: :index)
        |> Enum.map(fn [{start, len} | _] -> {start, start + len} end)
    end
  end

  defp overlaps_url?(_start, _len, []), do: false

  defp overlaps_url?(start, len, ranges) do
    stop = start + len
    Enum.any?(ranges, fn {url_start, url_stop} -> start < url_stop and stop > url_start end)
  end

  # A candidate glued to a box-drawing glyph is a fragment cut by a tmux
  # split seam (the path may continue in the neighbouring pane) — never
  # linkify it. Candidates *separated* from a divider by whitespace are fine.
  defp abuts_box_drawing?(text, start, len) do
    box_drawing?(grapheme_before(text, start)) or box_drawing?(grapheme_from(text, start + len))
  end

  defp grapheme_before(_text, 0), do: nil
  defp grapheme_before(text, pos), do: text |> binary_part(0, pos) |> String.last()

  defp grapheme_from(text, pos) when pos >= byte_size(text), do: nil

  defp grapheme_from(text, pos),
    do: text |> binary_part(pos, byte_size(text) - pos) |> String.first()

  # Box drawing (U+2500–U+257F) + block elements (U+2580–U+259F).
  defp box_drawing?(<<cp::utf8>>) when cp in 0x2500..0x259F, do: true
  defp box_drawing?(_grapheme), do: false

  # Capture layout: [full, path, line?, col?] as {start, len} byte ranges
  # ({-1, 0} when a group did not participate).
  defp build_link(text, [{full_start, full_len}, {path_start, path_len} | rest]) do
    path = binary_part(text, path_start, path_len)
    line = capture_int(text, rest)

    %{
      from: byte_to_col(text, full_start),
      to: byte_to_col(text, full_start + full_len) - 1,
      path: path,
      line: line
    }
  end

  defp capture_int(text, [{start, len} | _rest]) when start >= 0 and len > 0 do
    case Integer.parse(binary_part(text, start, len)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp capture_int(_text, _captures), do: nil

  # Cell columns == byte offsets on all-ASCII rows (the overwhelmingly common
  # case). Rows carrying multi-byte glyphs (dividers, powerline, unicode
  # output) convert via a grapheme count of the byte prefix — the row text is
  # built one grapheme per cell (see row_text/1), so grapheme index is the
  # column.
  defp byte_to_col(text, byte_offset) do
    if byte_size(text) == String.length(text) do
      byte_offset
    else
      text |> binary_part(0, byte_offset) |> String.length()
    end
  end
end
