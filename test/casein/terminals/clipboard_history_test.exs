defmodule Casein.Terminals.ClipboardHistoryTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.ClipboardHistory

  setup do
    ClipboardHistory.clear()
    on_exit(fn -> ClipboardHistory.clear() end)
    :ok
  end

  defp ws, do: "ws-clip-#{System.unique_integer([:positive])}"

  test "records a copy and broadcasts it to workspace subscribers" do
    workspace_id = ws()
    :ok = ClipboardHistory.subscribe(workspace_id)

    entry =
      ClipboardHistory.record(%{
        workspace_id: workspace_id,
        pane_id: "%12",
        pane_label: "claude",
        text: "mix test"
      })

    assert_receive {:clipboard_history, ^entry}
    assert entry.text == "mix test"
    assert entry.pane_label == "claude"
    assert entry.truncated? == false
    assert [^entry] = ClipboardHistory.recent(workspace_id)
  end

  test "keeps the newest copy first" do
    workspace_id = ws()

    first = ClipboardHistory.record(%{workspace_id: workspace_id, text: "first"})
    second = ClipboardHistory.record(%{workspace_id: workspace_id, text: "second"})

    assert [^second, ^first] = ClipboardHistory.recent(workspace_id)
  end

  test "bounds the history so a chatty agent cannot grow it without limit" do
    workspace_id = ws()

    for n <- 1..40 do
      ClipboardHistory.record(%{workspace_id: workspace_id, text: "copy-#{n}"})
    end

    entries = ClipboardHistory.recent(workspace_id, 100)

    assert Enum.count_until(entries, 21) == 20
    assert hd(entries).text == "copy-40"
    refute Enum.any?(entries, &(&1.text == "copy-1"))
  end

  test "a repeated copy refreshes in place instead of evicting distinct history" do
    workspace_id = ws()

    ClipboardHistory.record(%{workspace_id: workspace_id, text: "older"})
    ClipboardHistory.record(%{workspace_id: workspace_id, text: "same"})
    ClipboardHistory.record(%{workspace_id: workspace_id, text: "same"})

    assert ["same", "older"] = Enum.map(ClipboardHistory.recent(workspace_id), & &1.text)
  end

  test "re-copying an older value moves it to the top rather than duplicating it" do
    workspace_id = ws()

    ClipboardHistory.record(%{workspace_id: workspace_id, text: "a"})
    ClipboardHistory.record(%{workspace_id: workspace_id, text: "b"})
    ClipboardHistory.record(%{workspace_id: workspace_id, text: "a"})

    assert ["a", "b"] = Enum.map(ClipboardHistory.recent(workspace_id), & &1.text)
  end

  test "two viewers of one workspace extracting the same copy record it once" do
    # Every attached viewer LiveView sees the same PTY stream and independently
    # extracts the OSC 52 payload, so the store has to collapse them.
    workspace_id = ws()

    ClipboardHistory.record(%{workspace_id: workspace_id, pane_id: "%1", text: "shared"})
    ClipboardHistory.record(%{workspace_id: workspace_id, pane_id: "%1", text: "shared"})

    assert [_only] = ClipboardHistory.recent(workspace_id)
    assert ClipboardHistory.count(workspace_id) == 1
  end

  test "count reports retained copies without loading them" do
    workspace_id = ws()

    assert ClipboardHistory.count(workspace_id) == 0
    ClipboardHistory.record(%{workspace_id: workspace_id, text: "one"})
    ClipboardHistory.record(%{workspace_id: workspace_id, text: "two"})
    assert ClipboardHistory.count(workspace_id) == 2
  end

  test "truncates oversized payloads and flags them" do
    workspace_id = ws()

    entry =
      ClipboardHistory.record(%{workspace_id: workspace_id, text: String.duplicate("x", 70_000)})

    assert entry.truncated?
    assert entry.byte_size == 65_536
  end

  test "truncation keeps the text valid UTF-8" do
    workspace_id = ws()
    # "é" is two bytes, so a byte-aligned cut lands mid-grapheme.
    entry =
      ClipboardHistory.record(%{workspace_id: workspace_id, text: String.duplicate("é", 40_000)})

    assert entry.truncated?
    assert String.valid?(entry.text)
  end

  test "ignores blank text and copies with no workspace to attribute them to" do
    workspace_id = ws()

    assert ClipboardHistory.record(%{workspace_id: workspace_id, text: "   "}) == nil
    assert ClipboardHistory.record(%{workspace_id: workspace_id, text: ""}) == nil
    assert ClipboardHistory.record(%{workspace_id: nil, text: "orphan"}) == nil
    assert ClipboardHistory.recent(workspace_id) == []
  end

  test "history is per workspace" do
    one = ws()
    two = ws()

    ClipboardHistory.record(%{workspace_id: one, text: "for-one"})
    ClipboardHistory.record(%{workspace_id: two, text: "for-two"})

    assert ["for-one"] = Enum.map(ClipboardHistory.recent(one), & &1.text)
    assert ["for-two"] = Enum.map(ClipboardHistory.recent(two), & &1.text)
  end

  test "forget drops one workspace and leaves the others alone" do
    one = ws()
    two = ws()

    ClipboardHistory.record(%{workspace_id: one, text: "secret"})
    ClipboardHistory.record(%{workspace_id: two, text: "kept"})

    assert :ok = ClipboardHistory.forget(one)
    assert ClipboardHistory.recent(one) == []
    assert ["kept"] = Enum.map(ClipboardHistory.recent(two), & &1.text)
  end
end
