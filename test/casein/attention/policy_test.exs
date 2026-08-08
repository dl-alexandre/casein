defmodule Casein.Attention.PolicyTest do
  use Casein.TestCase, async: true

  alias Casein.Attention.Policy

  describe "surface_state/1" do
    test "passes through known atoms unchanged" do
      assert Policy.surface_state(:focused) == :focused
      assert Policy.surface_state(:visible) == :visible
      assert Policy.surface_state(:hidden) == :hidden
      assert Policy.surface_state(:unknown) == :unknown
    end

    test "normalizes known client strings to atoms" do
      assert Policy.surface_state("focused") == :focused
      assert Policy.surface_state("visible") == :visible
      assert Policy.surface_state("hidden") == :hidden
      assert Policy.surface_state("unknown") == :unknown
    end

    test "falls back to :unknown for unrecognized input" do
      assert Policy.surface_state("other") == :unknown
      assert Policy.surface_state("FOCUSED") == :unknown
      assert Policy.surface_state(nil) == :unknown
      assert Policy.surface_state(1) == :unknown
      assert Policy.surface_state(:background) == :unknown
    end

    test "atom and string normalizations produce distinct known states" do
      states =
        Enum.map([:focused, :visible, :hidden, :unknown], &Policy.surface_state/1)

      assert states == [:focused, :visible, :hidden, :unknown]
      assert length(Enum.uniq(states)) == 4
    end
  end

  describe "target_state/1" do
    test "passes through known atoms unchanged" do
      assert Policy.target_state(:focused) == :focused
      assert Policy.target_state(:visible) == :visible
      assert Policy.target_state(:hidden) == :hidden
      assert Policy.target_state(:unknown) == :unknown
    end

    test "normalizes known client strings to atoms" do
      assert Policy.target_state("focused") == :focused
      assert Policy.target_state("visible") == :visible
      assert Policy.target_state("hidden") == :hidden
      assert Policy.target_state("unknown") == :unknown
    end

    test "falls back to :unknown for unrecognized input" do
      assert Policy.target_state("other") == :unknown
      assert Policy.target_state("FOCUSED") == :unknown
      assert Policy.target_state(nil) == :unknown
      assert Policy.target_state(1) == :unknown
      assert Policy.target_state(:background) == :unknown
    end

    test "atom and string normalizations produce distinct known states" do
      states =
        Enum.map([:focused, :visible, :hidden, :unknown], &Policy.target_state/1)

      assert states == [:focused, :visible, :hidden, :unknown]
      assert length(Enum.uniq(states)) == 4
    end
  end

  describe "delivery_decision/1" do
    test "not observed_working? -> {:inline, :cold_ready} regardless of surface/target" do
      decision =
        Policy.delivery_decision(%{
          surface_state: :hidden,
          target_state: :hidden,
          observed_working?: false
        })

      assert decision.reaction == :inline
      assert decision.reason == :cold_ready
      assert decision.observed_working? == false
      assert decision.surface_state == :hidden
      assert decision.target_state == :hidden

      # Cold-ready wins over a focused pair that would otherwise be :nothing.
      focused_cold =
        Policy.delivery_decision(%{
          surface_state: :focused,
          target_state: :focused,
          observed_working?: false
        })

      assert focused_cold.reaction == :inline
      assert focused_cold.reason == :cold_ready
      refute focused_cold.reason == :focused_target
    end

    test "treats missing or non-true observed_working? as not working (cold_ready)" do
      for attrs <- [
            %{surface_state: :hidden, target_state: :hidden},
            %{surface_state: :hidden, target_state: :hidden, observed_working?: nil},
            %{surface_state: :hidden, target_state: :hidden, observed_working?: "true"},
            %{surface_state: :hidden, target_state: :hidden, observed_working?: 1}
          ] do
        decision = Policy.delivery_decision(attrs)
        assert decision.reaction == :inline
        assert decision.reason == :cold_ready
        assert decision.observed_working? == false
      end
    end

    test "surface focused and target focused -> {:nothing, :focused_target}" do
      decision =
        Policy.delivery_decision(%{
          surface_state: :focused,
          target_state: :focused,
          observed_working?: true
        })

      assert decision.reaction == :nothing
      assert decision.reason == :focused_target
      assert decision.observed_working? == true
      assert decision.surface_state == :focused
      assert decision.target_state == :focused

      # Distinct from the other working branches.
      refute decision.reaction == :inline
      refute decision.reaction == :notify
      refute decision.reason == :focused_workspace
      refute decision.reason == :background_surface
      refute decision.reason == :cold_ready
    end

    test "surface focused with non-focused target -> {:inline, :focused_workspace}" do
      for target <- [:visible, :hidden, :unknown] do
        decision =
          Policy.delivery_decision(%{
            surface_state: :focused,
            target_state: target,
            observed_working?: true
          })

        assert decision.reaction == :inline
        assert decision.reason == :focused_workspace
        assert decision.surface_state == :focused
        assert decision.target_state == target
        assert decision.observed_working? == true

        refute decision.reaction == :nothing
        refute decision.reaction == :notify
        refute decision.reason == :focused_target
        refute decision.reason == :background_surface
        refute decision.reason == :cold_ready
      end
    end

    test "non-focused surface while working -> {:notify, :background_surface}" do
      for surface <- [:visible, :hidden, :unknown],
          target <- [:focused, :visible, :hidden, :unknown] do
        decision =
          Policy.delivery_decision(%{
            surface_state: surface,
            target_state: target,
            observed_working?: true
          })

        assert decision.reaction == :notify
        assert decision.reason == :background_surface
        assert decision.surface_state == surface
        assert decision.target_state == target
        assert decision.observed_working? == true

        refute decision.reaction == :nothing
        refute decision.reaction == :inline
        refute decision.reason == :focused_target
        refute decision.reason == :focused_workspace
        refute decision.reason == :cold_ready
      end
    end

    test "normalizes string surface/target inputs in the returned decision" do
      decision =
        Policy.delivery_decision(%{
          surface_state: "focused",
          target_state: "visible",
          observed_working?: true
        })

      assert decision == %{
               reaction: :inline,
               reason: :focused_workspace,
               surface_state: :focused,
               target_state: :visible,
               observed_working?: true
             }
    end

    test "the four decision branches yield four distinct {reaction, reason} pairs" do
      branches = [
        Policy.delivery_decision(%{
          surface_state: :hidden,
          target_state: :hidden,
          observed_working?: false
        }),
        Policy.delivery_decision(%{
          surface_state: :focused,
          target_state: :focused,
          observed_working?: true
        }),
        Policy.delivery_decision(%{
          surface_state: :focused,
          target_state: :visible,
          observed_working?: true
        }),
        Policy.delivery_decision(%{
          surface_state: :hidden,
          target_state: :visible,
          observed_working?: true
        })
      ]

      pairs = Enum.map(branches, &{&1.reaction, &1.reason})

      assert pairs == [
               {:inline, :cold_ready},
               {:nothing, :focused_target},
               {:inline, :focused_workspace},
               {:notify, :background_surface}
             ]

      assert length(Enum.uniq(pairs)) == 4
      # Reasons alone are unique; reactions are not (two :inline paths).
      assert length(Enum.uniq(Enum.map(pairs, &elem(&1, 1)))) == 4
      assert length(Enum.uniq(Enum.map(pairs, &elem(&1, 0)))) == 3
    end
  end

  describe "delivery_reaction/1" do
    test "returns only the reaction from delivery_decision" do
      attrs_cold = %{
        surface_state: :hidden,
        target_state: :hidden,
        observed_working?: false
      }

      attrs_focused_target = %{
        surface_state: :focused,
        target_state: :focused,
        observed_working?: true
      }

      attrs_focused_workspace = %{
        surface_state: :focused,
        target_state: :visible,
        observed_working?: true
      }

      attrs_background = %{
        surface_state: :hidden,
        target_state: :visible,
        observed_working?: true
      }

      assert Policy.delivery_reaction(attrs_cold) == :inline
      assert Policy.delivery_reaction(attrs_focused_target) == :nothing
      assert Policy.delivery_reaction(attrs_focused_workspace) == :inline
      assert Policy.delivery_reaction(attrs_background) == :notify

      # Mirrors decision.reaction for each branch (transition is a thin projection).
      for attrs <- [attrs_cold, attrs_focused_target, attrs_focused_workspace, attrs_background] do
        assert Policy.delivery_reaction(attrs) ==
                 Policy.delivery_decision(attrs).reaction
      end

      reactions =
        Enum.map(
          [attrs_cold, attrs_focused_target, attrs_focused_workspace, attrs_background],
          &Policy.delivery_reaction/1
        )

      assert reactions == [:inline, :nothing, :inline, :notify]
      # Three distinct reaction atoms across four branches.
      assert MapSet.new(reactions) == MapSet.new([:inline, :nothing, :notify])
    end
  end

  describe "window_delivery/1" do
    test "quiet? true -> :inline" do
      assert Policy.window_delivery(%{quiet?: true}) == :inline
      refute Policy.window_delivery(%{quiet?: true}) == :nothing
    end

    test "quiet? false -> :nothing" do
      assert Policy.window_delivery(%{quiet?: false}) == :nothing
      refute Policy.window_delivery(%{quiet?: false}) == :inline
    end

    test "quiet? missing or non-true -> :nothing" do
      assert Policy.window_delivery(%{}) == :nothing
      assert Policy.window_delivery(%{quiet?: nil}) == :nothing
      assert Policy.window_delivery(%{quiet?: "true"}) == :nothing
      assert Policy.window_delivery(%{quiet?: 1}) == :nothing

      refute Policy.window_delivery(%{}) == :inline
    end

    test "true vs false produce distinct reactions" do
      assert Policy.window_delivery(%{quiet?: true}) !=
               Policy.window_delivery(%{quiet?: false})

      assert [
               Policy.window_delivery(%{quiet?: true}),
               Policy.window_delivery(%{quiet?: false})
             ] ==
               [:inline, :nothing]
    end
  end

  describe "reaction_label/1" do
    test "maps each reaction atom to its JSON-safe string" do
      assert Policy.reaction_label(:nothing) == "nothing"
      assert Policy.reaction_label(:inline) == "inline"
      assert Policy.reaction_label(:notify) == "notify"
    end

    test "labels are distinct and non-empty for all three reaction atoms" do
      labels =
        Enum.map([:nothing, :inline, :notify], &Policy.reaction_label/1)

      assert labels == ["nothing", "inline", "notify"]
      assert length(Enum.uniq(labels)) == 3
      assert Enum.all?(labels, &(is_binary(&1) and &1 != ""))
    end
  end
end
