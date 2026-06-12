defmodule TerminalCtl.ReplayTest do
  use ExUnit.Case, async: true

  alias TerminalCtl.Replay

  test "appends while under the limit" do
    assert Replay.append("abc", "def", 10) == "abcdef"
  end

  test "keeps the newest bytes when appending over the limit" do
    assert Replay.append("abcdef", "ghij", 6) == "efghij"
  end

  test "prefixes truncation marker without counting it against the retained tail" do
    assert Replay.append("abcdef", "ghij", 6, truncation_marker: "[truncated]\n") ==
             "[truncated]\nefghij"
  end
end
