defmodule TerminalCtl.EscapeTest do
  use DevIDE.TestCase, async: true

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

  test "supports DSR cursor reports with question mark prefix" do
    data = "x\e[?5;10Ry"

    assert Escape.strip_handshakes(data) ==
             {"xy", %{row: 5, col: 10, pending: false}}
  end

  test "uses the last cursor report when multiple appear in one chunk" do
    data = "a\e[1;1Rb\e[9;18Rc"

    assert Escape.strip_handshakes(data) ==
             {"abc", %{row: 9, col: 18, pending: false}}
  end

  test "leaves non-matching escape sequences intact" do
    data = "z\e[not-a-cursorRw"

    assert {clean, nil} = Escape.strip_handshakes(data)
    assert clean == data
  end
end
