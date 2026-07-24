defmodule Casein.Terminals.FileLinkScannerTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.FileLinkScanner

  describe "scan_row/1 — slash paths" do
    test "relative path with extension" do
      assert [%{path: "lib/foo.ex", line: nil, from: 0, to: 9}] =
               FileLinkScanner.scan_row("lib/foo.ex")
    end

    test "Elixir compile error format lib/foo.ex:12" do
      assert [%{path: "lib/foo.ex", line: 12, from: 0, to: 12}] =
               FileLinkScanner.scan_row("lib/foo.ex:12")
    end

    test "line and column /abs/p.c:3:7" do
      assert [%{path: "/abs/p.c", line: 3, from: 4, to: 15}] =
               FileLinkScanner.scan_row("gcc /abs/p.c:3:7: error: oops")
    end

    test "dot-slash prefix ./a/b.js" do
      assert [%{path: "./a/b.js", line: nil}] = FileLinkScanner.scan_row("bundling ./a/b.js now")
    end

    test "parent prefix ../shared/util.ts:4" do
      assert [%{path: "../shared/util.ts", line: 4}] =
               FileLinkScanner.scan_row("see ../shared/util.ts:4")
    end

    test "Elixir stacktrace line" do
      row = "    (dev_ide 0.1.0) lib/dev_ide/file_panes.ex:91: Casein.FilePanes.open/3"

      assert [%{path: "lib/dev_ide/file_panes.ex", line: 91}] = FileLinkScanner.scan_row(row)
    end

    test "ExUnit failure location" do
      row = "  test/dev_ide/files_test.exs:42: (test)"

      assert [%{path: "test/dev_ide/files_test.exs", line: 42}] = FileLinkScanner.scan_row(row)
    end

    test "deps stacktrace path is a candidate too" do
      assert [%{path: "deps/phoenix/lib/phoenix.ex", line: 7}] =
               FileLinkScanner.scan_row("(phoenix 1.8.0) deps/phoenix/lib/phoenix.ex:7: fun/1")
    end

    test "column ranges cover the :line suffix and are cell-accurate" do
      row = "== lib/a.ex:3 =="
      assert [%{from: 3, to: 12}] = FileLinkScanner.scan_row(row)
      assert String.slice(row, 3..12) == "lib/a.ex:3"
    end
  end

  describe "scan_row/1 — bare names on the extension allowlist" do
    test "bare file with known extension" do
      assert [%{path: "mix.exs", line: nil}] = FileLinkScanner.scan_row("update mix.exs please")
    end

    test "bare file with :line" do
      assert [%{path: "config.yaml", line: 3}] = FileLinkScanner.scan_row("config.yaml:3")
    end

    test "unknown bare extension does not match" do
      assert [] = FileLinkScanner.scan_row("see foo.zzz and bar.binx")
    end

    test "elixir module/function references do not match" do
      assert [] = FileLinkScanner.scan_row("Casein.FilePanes.open_file_in_pane/3 and Enum.map/2")
    end

    test "version numbers do not match" do
      assert [] = FileLinkScanner.scan_row("elixir 1.20.0-otp-28 and 0.1.0")
    end

    test "multi-dot names only match when the final extension is known" do
      assert [] = FileLinkScanner.scan_row("archive foo.ex.bak kept")
      assert [%{path: "app.config.js"}] = FileLinkScanner.scan_row("edit app.config.js")
    end
  end

  describe "scan_row/1 — punctuation stripping" do
    test "trailing sentence period is not part of the match" do
      assert [%{path: "lib/foo.ex", line: nil}] = FileLinkScanner.scan_row("Fixed lib/foo.ex.")
      assert [%{path: "mix.exs", line: nil}] = FileLinkScanner.scan_row("Edit mix.exs.")
    end

    test "wrapping parens/quotes/brackets are excluded" do
      assert [%{path: "lib/foo.ex", line: 3}] = FileLinkScanner.scan_row("(lib/foo.ex:3)")
      assert [%{path: "lib/foo.ex", line: nil}] = FileLinkScanner.scan_row(~s{"lib/foo.ex",})
      assert [%{path: "lib/foo.ex", line: 9}] = FileLinkScanner.scan_row("[lib/foo.ex:9]:")
    end

    test "trailing bare colon is not consumed" do
      assert [%{path: "lib/foo.ex", line: nil, to: to}] =
               FileLinkScanner.scan_row("lib/foo.ex: warning")

      assert to == 9
    end
  end

  describe "scan_row/1 — rejections" do
    test "box-drawing divider glyphs never join a match" do
      # A vertical tmux split seam between two panes: the path fragments on
      # either side of the divider must not fuse into one link.
      assert [] = FileLinkScanner.scan_row("lib/fo│o.ex")

      assert [] =
               FileLinkScanner.scan_row("─────┤ tmp.ex├─────" |> String.replace("tmp.ex", "x.zz"))
    end

    test "paths adjacent to dividers still match with correct cell columns" do
      row = "│ lib/foo.ex:3 │"

      assert [%{path: "lib/foo.ex", line: 3, from: 2, to: 13}] = FileLinkScanner.scan_row(row)
      # Cell columns, not byte offsets: the divider is multi-byte.
      assert row |> String.graphemes() |> Enum.slice(2..13) |> Enum.join() == "lib/foo.ex:3"
    end

    test "URLs do not produce path matches" do
      assert [] = FileLinkScanner.scan_row("https://example.com/lib/foo.ex fetched")
      assert [] = FileLinkScanner.scan_row("http://localhost:4000/assets/app.js")
    end

    test "rows without dot or slash are gated before the regex" do
      assert [] = FileLinkScanner.scan_row("plain prompt $ ")
      assert [] = FileLinkScanner.scan_row(String.duplicate("─", 80))
    end

    test "at most eight candidates per row" do
      row = Enum.map_join(1..12, " ", &"lib/f#{&1}.ex")
      assert length(FileLinkScanner.scan_row(row)) == 8
    end
  end

  describe "scan_rows/1" do
    test "tags candidates with their row index" do
      rows = [{0, "ok"}, {3, "lib/foo.ex:1"}, {5, "mix.exs"}]

      assert [
               %{row: 3, path: "lib/foo.ex", line: 1},
               %{row: 5, path: "mix.exs", line: nil}
             ] = FileLinkScanner.scan_rows(rows)
    end
  end

  describe "row_text/1" do
    test "renders one grapheme per cell with blanks for empty cells" do
      cells = [
        {"l", nil, nil, 0},
        {"i", nil, nil, 0},
        {"b", nil, nil, 0},
        {nil, nil, nil, 0},
        {"", nil, nil, 0},
        {"│", [1, 2, 3], nil, 8}
      ]

      assert FileLinkScanner.row_text(cells) == "lib  │"
    end

    test "grep-style chains linkify the leading path" do
      assert [%{path: "lib/foo.ex", line: 12} | _] =
               FileLinkScanner.scan_row("lib/foo.ex:12:  import Bar")
    end
  end
end
