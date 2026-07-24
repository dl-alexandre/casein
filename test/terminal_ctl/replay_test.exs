defmodule TerminalCtl.ReplayTest do
  use Casein.TestCase, async: true

  alias TerminalCtl.Replay

  test "appends while under the limit" do
    assert Replay.append("abc", "def", 10) == "abcdef"
  end

  test "keeps the newest bytes when appending over the limit" do
    assert Replay.append("abcdef", "ghij", 6) == "efghij"
  end

  test "ignores old buffer when new data exceeds the limit" do
    assert Replay.append("abc", "123456789", 4) == "6789"
  end

  test "accepts iodata input" do
    assert Replay.append("", ["hel", "lo"], 10) == "hello"
  end

  test "prefixes truncation marker without counting it against the retained tail" do
    assert Replay.append("abcdef", "ghij", 6, truncation_marker: "[truncated]\n") ==
             "[truncated]\nefghij"
  end

  test "appends to an already marked buffer using the newest retained tail" do
    assert Replay.append("[truncated]\nefghij", "kl", 6, truncation_marker: "[truncated]\n") ==
             "[truncated]\nghijkl"
  end
end
