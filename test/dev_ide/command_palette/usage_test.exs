defmodule DevIDE.CommandPalette.UsageTest do
  use DevIDE.DataCase, async: true

  alias DevIDE.CommandPalette.Usage

  test "record upserts and increments per workspace+item" do
    assert :ok = Usage.record("ws-usage", "tmux:zoom")
    assert :ok = Usage.record("ws-usage", "tmux:zoom")
    assert :ok = Usage.record("ws-usage", "tab:files")

    usage = Usage.for_workspace("ws-usage")

    assert %{uses: 2, last_used_at: %DateTime{}} = usage["tmux:zoom"]
    assert %{uses: 1} = usage["tab:files"]
  end

  test "usage is scoped by workspace" do
    assert :ok = Usage.record("ws-a", "tmux:zoom")

    assert Usage.for_workspace("ws-b") == %{}
    assert Map.has_key?(Usage.for_workspace("ws-a"), "tmux:zoom")
  end

  test "record ignores blank item ids" do
    assert :ok = Usage.record("ws-usage", "")
    assert Usage.for_workspace("ws-usage") == %{}
  end

  test "for_workspace caps the ranking window" do
    for i <- 1..5, do: Usage.record("ws-cap", "item:#{i}")

    usage = Usage.for_workspace("ws-cap", 3)
    assert map_size(usage) == 3
  end
end
