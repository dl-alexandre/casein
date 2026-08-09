defmodule Casein.Attention.DeliveryTest do
  use ExUnit.Case, async: true

  alias Casein.Attention.{Delivery, Salience}

  describe "delivery_decision/1" do
    test "preserves Policy focus table (post-#696 delivery_* vocabulary)" do
      assert Delivery.delivery_decision(%{
               surface_state: :hidden,
               target_state: :hidden,
               observed_working?: false
             }).reason == :cold_ready

      assert Delivery.delivery_decision(%{
               surface_state: :focused,
               target_state: :focused,
               observed_working?: true
             }) == %{
               reaction: :nothing,
               reason: :focused_target,
               surface_state: :focused,
               target_state: :focused,
               observed_working?: true
             }

      assert Delivery.delivery_reaction(%{
               surface_state: :hidden,
               target_state: :visible,
               observed_working?: true
             }) == :notify
    end
  end

  describe "window_delivery/1" do
    test "quiet window is inline chrome only" do
      assert Delivery.window_delivery(%{quiet?: true}) == :inline
      assert Delivery.window_delivery(%{quiet?: false}) == :nothing
    end
  end

  describe "session_classification/1" do
    test "idle signal is needs_you idle — not a suppress reason" do
      assert Delivery.session_classification(%{signal: :idle}) == %{
               section: :needs_you,
               reason: :idle
             }
    end

    test "errored and stalled reasons stay distinct from blocked" do
      assert Delivery.session_classification(%{signal: :agent_errored}) == %{
               section: :needs_you,
               reason: :errored
             }

      assert Delivery.session_classification(%{signal: :agent_stalled}) == %{
               section: :needs_you,
               reason: :stalled
             }
    end
  end

  # ---------------------------------------------------------------------------
  # #699 / H28 — one known salience → expected presence/absence on each surface
  # ---------------------------------------------------------------------------

  describe "surface thresholds over shared salience (#699 / H28)" do
    test "inspectable floors and push signal set are readable constants" do
      assert Delivery.notify_rank_floor() == 400
      assert Delivery.session_needs_you_rank_floor() == 400
      assert MapSet.member?(Delivery.push_signals(), :agent_blocked)
      refute MapSet.member?(Delivery.push_signals(), :idle)
      refute MapSet.member?(Delivery.push_signals(), :agent_stalled)
    end

    test "blocked agent: push + drawer + needs_you; pin when decision card" do
      salience =
        Salience.compute(%{
          agent_states: [:blocked],
          quiet?: false,
          lifecycle_status: :other
        })

      assert salience.rank == 700
      assert Delivery.notify_eligible?(salience)
      assert Delivery.push_eligible?(salience)
      assert Delivery.drawer_eligible?(salience)
      assert Delivery.session_needs_you?(salience)
      assert Delivery.session_classification(salience) == %{section: :needs_you, reason: :blocked}
      assert Delivery.session_reason_urgency(:blocked) == 0
      assert Delivery.drawer_severity(salience.priority) == "warning"

      assert Delivery.needs_me_pin?(%{type: :clarification, status: "open"})
      refute Delivery.needs_me_pin?(%{type: :clarification, status: "resolved"})
      refute Delivery.needs_me_pin?(%{type: :run, status: "open"})
    end

    test "errored agent: cockpit needs_you + push; reason errored not blocked" do
      salience =
        Salience.compute(%{
          agent_states: [:errored],
          quiet?: false,
          lifecycle_status: :other
        })

      assert salience.signal == :agent_errored
      assert Delivery.session_needs_you?(salience)
      assert Delivery.push_eligible?(salience)
      assert Delivery.session_classification(salience).reason == :errored
      assert Delivery.session_reason_urgency(:errored) == 0
    end

    test "stalled agent: cockpit needs_you, not a phone interrupt" do
      salience =
        Salience.compute(%{
          agent_states: [:stalled],
          quiet?: false,
          lifecycle_status: :other
        })

      assert salience.signal == :agent_stalled
      assert Delivery.session_needs_you?(salience)
      assert Delivery.session_classification(salience).reason == :stalled
      # notify bit is false → neither drawer create nor push
      refute Delivery.notify_eligible?(salience)
      refute Delivery.push_eligible?(salience)
      refute Delivery.drawer_eligible?(salience)
      assert Delivery.session_reason_urgency(:stalled) == 1
    end

    test "completed work: notify true (rank 400) on push/drawer and needs_you" do
      salience =
        Salience.compute(%{
          agent_states: [:done],
          quiet?: false,
          lifecycle_status: :other
        })

      assert salience.rank == 400
      assert Delivery.push_eligible?(salience)
      assert Delivery.drawer_eligible?(salience)
      assert Delivery.session_needs_you?(salience)
      assert Delivery.session_classification(salience).reason == :completed
      assert Delivery.session_reason_urgency(:completed) == 2
      assert Delivery.drawer_severity(salience.priority) == "info"
    end

    test "idle (went quiet): cockpit needs_you + chrome; not OS push" do
      salience =
        Salience.compute(%{
          agent_states: [],
          quiet?: true,
          lifecycle_status: :other
        })

      assert salience.signal == :idle
      assert salience.rank == 400
      # Drawer/notify floor still true (operator chrome); push is a separate cut.
      assert Delivery.notify_eligible?(salience)
      assert Delivery.drawer_eligible?(salience)
      refute Delivery.push_eligible?(salience)
      assert Delivery.session_needs_you?(salience)
      assert Delivery.session_classification(salience) == %{section: :needs_you, reason: :idle}
      assert Delivery.session_reason_urgency(:idle) == 3

      assert Delivery.chrome_attention_label(1, 1) == "unseen"
      assert Delivery.chrome_attention_label(0, 1) == "inline"
      assert Delivery.chrome_attention_label(0, 0) == "nothing"
      assert Delivery.window_chrome_attention(true, true) == "unseen"
      assert Delivery.window_chrome_attention(true, false) == "inline"
      assert Delivery.window_chrome_attention(false, false) == "nothing"
    end

    test "working: below notify floor; session section working, not needs_you" do
      salience =
        Salience.compute(%{
          agent_states: [:working],
          quiet?: false,
          lifecycle_status: :other
        })

      assert salience.rank == 120
      refute Delivery.notify_eligible?(salience)
      refute Delivery.push_eligible?(salience)
      refute Delivery.drawer_eligible?(salience)
      refute Delivery.session_needs_you?(salience)
      assert Delivery.session_classification(salience) == %{section: :working, reason: :working}
    end

    test "informational: absent from push, drawer create, and needs_you" do
      salience =
        Salience.compute(%{
          agent_states: [],
          quiet?: false,
          lifecycle_status: :other
        })

      assert salience.rank == 80
      refute Delivery.push_eligible?(salience)
      refute Delivery.drawer_eligible?(salience)
      refute Delivery.session_needs_you?(salience)
      assert Delivery.session_classification(salience).section == :recent
    end

    test "push and cockpit are distinct decisions over the same salience" do
      idle =
        Salience.compute(%{
          agent_states: [],
          quiet?: true,
          lifecycle_status: :other
        })

      blocked =
        Salience.compute(%{
          agent_states: [:blocked],
          quiet?: false,
          lifecycle_status: :other
        })

      # Same definition; different thresholds.
      assert Delivery.session_needs_you?(idle)
      refute Delivery.push_eligible?(idle)
      assert Delivery.session_needs_you?(blocked)
      assert Delivery.push_eligible?(blocked)
    end
  end
end
