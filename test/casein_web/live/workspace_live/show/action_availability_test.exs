defmodule CaseinWeb.WorkspaceLive.Show.ActionAvailabilityTest do
  use Casein.TestCase, async: true

  alias Casein.CommandPalette.Actions
  alias CaseinWeb.WorkspaceLive.Show.ActionAvailability, as: Avail

  defp ctx(overrides \\ %{}) do
    Avail.context(
      Map.merge(
        %{
          tmux_mutations_enabled?: true,
          tmux_session: "devide-ws",
          terminal_mode: :raw,
          tmux_panes: [%{id: "%1"}, %{id: "%2"}]
        },
        overrides
      )
    )
  end

  describe "context/1" do
    test "reads from a bare assigns map or a socket" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, terminal_mode: :raw}}

      assert Avail.context(socket).raw_terminal?
      refute Avail.context(%{}).raw_terminal?
    end

    test "treats a missing tmux session as absent rather than crashing" do
      refute Avail.context(%{}).tmux_session?
      assert Avail.context(%{}).pane_count == 0
    end
  end

  describe "available?/2 — hard gates" do
    test "mutation verbs require the tmux-mutation gate" do
      assert Avail.available?("tmux:new_window", ctx())
      refute Avail.available?("tmux:new_window", ctx(%{tmux_mutations_enabled?: false}))
    end

    test "pane structure verbs require the raw terminal surface" do
      assert Avail.available?("split_right", ctx())
      refute Avail.available?("split_right", ctx(%{terminal_mode: :governed}))
    end

    test "pane navigation requires a live tmux session" do
      assert Avail.available?("pane:navigate", ctx())
      refute Avail.available?("pane:navigate", ctx(%{tmux_session: nil}))
    end

    test "actions with no rule are always available" do
      assert Avail.available?("palette:open", ctx(%{tmux_mutations_enabled?: false}))
      assert Avail.available?("", ctx())
    end
  end

  describe "relevant?/2 — soft gate" do
    test "pane verbs are irrelevant with a single pane but still available" do
      single = ctx(%{tmux_panes: [%{id: "%1"}]})

      refute Avail.relevant?("tmux:cycle_layout", single)

      assert Avail.available?("tmux:cycle_layout", single),
             "single-pane is a relevance rule, not a denial — search must still reach it"
    end

    test "pane verbs are relevant once a second pane exists" do
      assert Avail.relevant?("tmux:cycle_layout", ctx())
    end
  end

  describe "item_available?/2" do
    test "clears both the item id and the event it dispatches" do
      # "tmux:split_right" dispatches "split_right"; the raw-terminal rule is
      # keyed by the event, so gating on the id alone would miss it.
      item = Enum.find(Actions.all(), &(&1.id == "tmux:split_right"))

      assert item, "expected a tmux:split_right action in the catalog"
      assert Avail.item_available?(item, ctx())
      refute Avail.item_available?(item, ctx(%{terminal_mode: :governed}))
    end

    test "an item whose payload names no event is unrestricted" do
      assert Avail.item_available?(%{id: "some:thing", payload: %{}}, ctx())
    end
  end

  describe "surface agreement" do
    test "no catalog action is permanently unavailable in the default state" do
      # A catalog entry that can never be offered is dead weight in the palette;
      # this catches a rule added with a typo'd key or an over-broad gate.
      unreachable =
        Actions.all()
        |> Enum.reject(&Avail.item_available?(&1, ctx()))
        |> Enum.map(& &1.id)

      assert unreachable == []
    end
  end
end
