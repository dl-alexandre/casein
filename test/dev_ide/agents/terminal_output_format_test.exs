defmodule DevIDE.Agents.TerminalOutputFormatTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Agents.TerminalOutputFormat

  test "strips CSI color sequences by default" do
    assert TerminalOutputFormat.format("\e[31merror\e[0m\n") == "error\n"
  end

  test "normalizes CRLF newlines" do
    assert TerminalOutputFormat.format("line1\r\nline2") == "line1\nline2"
  end

  test "passes output through unchanged when ansi is true" do
    raw = "\e[31merror\e[0m\r\n"
    assert TerminalOutputFormat.format(raw, ansi: true) == raw
  end

  test "leaves plain text unchanged" do
    assert TerminalOutputFormat.format("plain output\n") == "plain output\n"
  end

  test "passes literal tab characters through unchanged" do
    assert TerminalOutputFormat.format("col1\tcol2\n") == "col1\tcol2\n"
  end

  test "passes literal tabs through even when surrounded by ANSI codes" do
    raw = "\e[31mleft\e[0m\t\e[32mright\e[0m\n"
    assert TerminalOutputFormat.format(raw) == "left\tright\n"
  end

  test "passes U+FFFD replacement bytes through unchanged" do
    assert TerminalOutputFormat.format("bad\xFF\xFEbyte\n") == "bad\xFF\xFEbyte\n"
  end
end
