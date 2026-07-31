defmodule Casein.Terminals.WebLinkScannerTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.WebLinkScanner

  describe "scan_row/1" do
    test "plain https URL, cell columns are inclusive" do
      assert [%{url: "https://example.com", from: 0, to: 18}] =
               WebLinkScanner.scan_row("https://example.com")
    end

    test "http URL embedded in a log line" do
      assert [%{url: "http://localhost:4000/foo", from: 8, to: 32}] =
               WebLinkScanner.scan_row("open at http://localhost:4000/foo now")
    end

    test "trailing sentence punctuation is trimmed" do
      assert [%{url: "https://example.com/x"}] =
               WebLinkScanner.scan_row("see https://example.com/x.")
    end

    test "wrapping parenthesis is trimmed" do
      assert [%{url: "https://example.com"}] =
               WebLinkScanner.scan_row("(https://example.com)")
    end

    test "multiple URLs on one row" do
      assert [%{url: "http://a.test"}, %{url: "https://b.test"}] =
               WebLinkScanner.scan_row("http://a.test and https://b.test")
    end

    test "non-http schemes are ignored" do
      assert [] = WebLinkScanner.scan_row("file:///etc/passwd ftp://host/x")
    end

    test "rows without :// never match (cheap gate)" do
      assert [] = WebLinkScanner.scan_row("$ mix test --cover")
    end

    test "columns account for multi-byte glyphs before the URL" do
      # A box-drawing divider (3 bytes, 1 cell) precedes the URL: the byte
      # offset (10) must map to cell column 8.
      assert [%{url: "https://x.io", from: 8}] =
               WebLinkScanner.scan_row("│ go to https://x.io")
    end

    test "non-binary input is safe" do
      assert [] = WebLinkScanner.scan_row(nil)
    end
  end

  describe "scan_rows/1" do
    test "tags each link with its row index and skips URL-free rows" do
      rows = [{0, "prompt $"}, {3, "visit https://z.dev"}]

      assert [%{row: 3, url: "https://z.dev", from: 6}] = WebLinkScanner.scan_rows(rows)
    end

    test "reconstructs a URL soft-wrapped across terminal rows" do
      url = "https://example.com/a/very/long/path"
      rows = wrapped_rows(url, 13, 4)

      links = WebLinkScanner.scan_rows(rows)

      assert Enum.map(links, & &1.row) == [4, 5, 6]
      assert Enum.all?(links, &(&1.url == url))
      assert Enum.at(links, 0) == %{row: 4, from: 0, to: 12, url: url}
      assert Enum.at(links, 1) == %{row: 5, from: 0, to: 12, url: url}
      assert List.last(links) == %{row: 6, from: 0, to: 9, url: url}
    end

    test "trims punctuation after the final wrapped segment" do
      url = "https://example.com/a/very/long/path"
      [first | rest] = wrapped_rows(url <> ".", 20, 0)

      assert links = WebLinkScanner.scan_rows([first | rest])
      assert Enum.all?(links, &(&1.url == url))
      assert List.last(links).to == 15
    end

    test "does not join a second URL that starts on the next row" do
      rows = [{0, "https://one.test/x"}, {1, "https://two.test/y"}]

      assert [
               %{row: 0, url: "https://one.test/x"},
               %{row: 1, url: "https://two.test/y"}
             ] = WebLinkScanner.scan_rows(rows)
    end
  end

  defp wrapped_rows(text, width, first_row) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
    |> List.update_at(-1, &String.pad_trailing(&1, width))
    |> Enum.with_index(first_row)
    |> Enum.map(fn {row, index} -> {index, row} end)
  end
end
