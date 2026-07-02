defmodule DevIDE.CommandPalette.RecentsTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.CommandPalette.Recents

  # The Recents server (and its named ETS table) is started by the app
  # supervision tree; tests isolate on unique workspace ids.
  defp ws, do: "ws-recents-#{System.unique_integer([:positive])}"

  test "list is empty for an unknown workspace" do
    assert Recents.list(ws()) == []
    assert Recents.ranks(ws()) == %{}
  end

  test "record keeps most-recent-first order" do
    id = ws()
    Recents.record(id, "command:test")
    Recents.record(id, "tab:files")
    Recents.record(id, "tmux:zoom")

    assert Recents.list(id) == ["tmux:zoom", "tab:files", "command:test"]
    assert Recents.ranks(id) == %{"tmux:zoom" => 0, "tab:files" => 1, "command:test" => 2}
  end

  test "re-recording an id moves it to the front without duplicating" do
    id = ws()
    Recents.record(id, "a")
    Recents.record(id, "b")
    Recents.record(id, "a")

    assert Recents.list(id) == ["a", "b"]
  end

  test "history is capped" do
    id = ws()

    for n <- 1..(Recents.cap() + 10) do
      Recents.record(id, "item:#{n}")
    end

    ids = Recents.list(id)
    assert length(ids) == Recents.cap()
    assert hd(ids) == "item:#{Recents.cap() + 10}"
    refute "item:1" in ids
  end

  test "workspaces are isolated" do
    a = ws()
    b = ws()
    Recents.record(a, "only-in-a")

    assert Recents.list(a) == ["only-in-a"]
    assert Recents.list(b) == []
  end

  test "non-binary input is a no-op" do
    assert Recents.record(nil, "x") == :ok
    assert Recents.record("ws", nil) == :ok
    assert Recents.list(nil) == []
  end
end
