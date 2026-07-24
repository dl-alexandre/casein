defmodule Casein.Terminals.SyncOutputTest do
  use Casein.TestCase, async: true

  alias Casein.Terminals.SyncOutput

  @bsu "\e[?2026h"
  @esu "\e[?2026l"

  test "no toggle leaves the state unchanged" do
    assert SyncOutput.active_after?("plain text", false) == false
    assert SyncOutput.active_after?("plain text", true) == true
    assert SyncOutput.active_after?("", false) == false
  end

  test "BSU opens, ESU closes a synchronized update" do
    assert SyncOutput.active_after?(@bsu, false) == true
    assert SyncOutput.active_after?(@esu, true) == false
  end

  test "a complete BSU…ESU pair in one chunk ends closed" do
    chunk = @bsu <> "\e[2J\e[Hrepainted screen" <> @esu
    assert SyncOutput.active_after?(chunk, false) == false
  end

  test "an opened-but-not-closed update ends active" do
    chunk = @bsu <> "partial frame, more coming"
    assert SyncOutput.active_after?(chunk, false) == true
  end

  test "the last toggle in the chunk wins" do
    # close then immediately reopen -> still active
    assert SyncOutput.active_after?(@esu <> "x" <> @bsu, true) == true
    # open then close -> not active
    assert SyncOutput.active_after?(@bsu <> "x" <> @esu, false) == false
  end

  test "ignores unrelated private modes" do
    assert SyncOutput.active_after?("\e[?25l\e[?1049h", false) == false
  end
end
