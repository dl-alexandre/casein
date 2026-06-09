defmodule DevIDE.BoundedBufferTest do
  use ExUnit.Case, async: true

  alias DevIDE.BoundedBuffer

  test "appends while under the limit" do
    assert BoundedBuffer.append("abc", "def", 10) == "abcdef"
  end

  test "keeps the newest bytes when appending over the limit" do
    assert BoundedBuffer.append("abcdef", "ghij", 6) == "efghij"
  end

  test "ignores old buffer when new data exceeds the limit" do
    assert BoundedBuffer.append("abc", "123456789", 4) == "6789"
  end

  test "prefixes truncation marker without counting it against the retained tail" do
    assert BoundedBuffer.append("abcdef", "ghij", 6, truncation_marker: "[truncated]\n") ==
             "[truncated]\nefghij"
  end

  test "appends to an already marked buffer using the newest retained tail" do
    assert BoundedBuffer.append("[truncated]\nefghij", "kl", 6,
             truncation_marker: "[truncated]\n"
           ) == "[truncated]\nghijkl"
  end
end
