defmodule Casein.BoundedBufferFacadeTest do
  use Casein.TestCase, async: true

  alias Casein.BoundedBuffer
  alias TerminalCtl.Replay

  test "facade delegates append/4 to TerminalCtl.Replay" do
    assert BoundedBuffer.append("abc", "def", 10) == Replay.append("abc", "def", 10)

    assert BoundedBuffer.append("abcdef", "ghij", 6, truncation_marker: "…") ==
             Replay.append("abcdef", "ghij", 6, truncation_marker: "…")
  end
end
