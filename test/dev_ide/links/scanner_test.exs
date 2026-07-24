defmodule Casein.Links.ScannerTest do
  use Casein.TestCase, async: true

  alias Casein.Links.Scanner

  test "scans URLs and plausible paths in row order" do
    spans = Scanner.scan_row(~s|see (lib/foo.ex:3), then http://localhost:4000/app.|)

    assert Enum.map(spans, & &1.raw) == ["lib/foo.ex:3", "http://localhost:4000/app"]
    assert [%{col_start: 5, col_end: 17}, %{col_start: 25}] = spans
  end

  test "finds extension-only paths but avoids bare words" do
    spans = Scanner.scan_row("mix.exs:5 config lib README")

    assert Enum.map(spans, & &1.raw) == ["mix.exs:5"]
  end

  test "does not emit path candidates inside URLs" do
    spans = Scanner.scan_row("open https://example.com/lib/foo.ex")

    assert Enum.map(spans, & &1.raw) == ["https://example.com/lib/foo.ex"]
  end

  test "does not linkify bare path anchors" do
    assert Scanner.scan_row("either / or ./ or ../") == []
  end
end
