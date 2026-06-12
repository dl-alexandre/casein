defmodule TerminalCtl.EscapeTest do
  use ExUnit.Case, async: true

  alias TerminalCtl.Escape

  test "passes through data without escape sequences" do
    assert Escape.strip_handshakes("hello") == {"hello", nil}
  end

  test "strips cursor report and returns cursor position" do
    data = "prompt\e[12;34Rmore"

    assert Escape.strip_handshakes(data) ==
             {"promptmore", %{row: 12, col: 34, pending: false}}
  end

  test "strips xtversion and device attribute probes" do
    data = "a\e[>0q\eP>|ghostty 1.0\e\\b\e[?1c"

    assert {clean, nil} = Escape.strip_handshakes(data)
    assert clean == "ab"
  end
end
