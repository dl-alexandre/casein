defmodule DevIDE.CommandPalette.ActionsTest do
  use ExUnit.Case, async: true

  alias DevIDE.CommandPalette.Actions
  alias DevIDE.CommandPalette.Item

  describe "all/0" do
    setup do
      %{items: Actions.all()}
    end

    test "returns a non-empty allowlist of Item structs", %{items: items} do
      assert length(items) > 10
      assert Enum.all?(items, &match?(%Item{}, &1))
    end

    test "every item carries an id, label, and event payload", %{items: items} do
      for item <- items do
        assert is_binary(item.id) and item.id != ""
        assert is_binary(item.label) and item.label != ""
        assert is_binary(item.payload.event)
        assert is_map(item.payload.params)
      end
    end

    test "every dispatched event is in the allowed_events allowlist", %{items: items} do
      allowed = Actions.allowed_events()

      for item <- items do
        assert MapSet.member?(allowed, item.payload.event),
               "#{item.id} dispatches unlisted event #{item.payload.event}"
      end
    end

    test "item ids are unique", %{items: items} do
      ids = Enum.map(items, & &1.id)
      assert length(ids) == length(Enum.uniq(ids))
    end

    test "includes a tab item per known tab", %{items: items} do
      tab_ids = items |> Enum.filter(&(&1.kind == :tab)) |> Enum.map(& &1.id)

      assert "tab:terminal" in tab_ids
      assert "tab:files" in tab_ids
      assert "tab:agents" in tab_ids
      assert "tab:proposals" in tab_ids
      assert length(tab_ids) == 8
    end

    test "includes structural tmux pane verbs under the tmux category", %{items: items} do
      tmux = Enum.filter(items, &(&1.category == :tmux))
      events = Enum.map(tmux, & &1.payload.event)

      assert "split_right" in events
      assert "pane:zoom_focused" in events
      assert "equalize_layout" in events
    end

    test "includes preview and agents actions", %{items: items} do
      ids = Enum.map(items, & &1.id)
      assert "preview:open-url" in ids
      assert "agents:apply_pair" in ids
      assert "audit:drawer" in ids
    end
  end

  describe "allowed_events/0" do
    test "is a MapSet covering the gated mutation verbs" do
      allowed = Actions.allowed_events()
      assert %MapSet{} = allowed
      assert MapSet.member?(allowed, "switch_tab")
      assert MapSet.member?(allowed, "run:start")
      assert MapSet.member?(allowed, "preview:open")
    end
  end
end
