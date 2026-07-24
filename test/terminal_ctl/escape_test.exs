defmodule TerminalCtl.EscapeTest do
  use Casein.TestCase, async: true

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

  describe "strip_color_queries/1" do
    test "passes through data without OSC sequences" do
      assert Escape.strip_color_queries("plain\e[31mred\e[0m") == "plain\e[31mred\e[0m"
    end

    test "removes OSC 10/11/12 color queries with BEL and ST terminators" do
      data = "a\e]10;?\ab\e]11;?\e\\c\e]12;?\ad"

      assert Escape.strip_color_queries(data) == "abcd"
    end

    test "removes OSC 4 palette queries including multi-entry forms" do
      data = "x\e]4;7;?\ay\e]4;1;?;2;?\e\\z"

      assert Escape.strip_color_queries(data) == "xyz"
    end

    test "preserves set-forms and color replies" do
      data =
        "\e]11;#112233\a" <>
          "\e]10;rgb:cdcd/d6d6/f4f4\a" <>
          "\e]4;1;#f38ba8\a" <>
          "\e]4;2;rgb:0000/ffff/0000\e\\"

      assert Escape.strip_color_queries(data) == data
    end
  end
end
