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
  end

  # ---------------------------------------------------------------------------
  # #699 — one known salience → expected presence/absence on each surface gate
  # ---------------------------------------------------------------------------

  describe "surface thresholds over shared salience (#699)" do
    test "inspectable floors are readable constants" do
      assert Delivery.notify_rank_floor() == 400
      assert Delivery.session_needs_you_rank_floor() == 400
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
      assert Delivery.session_reason_urgency(:completed) == 1
      assert Delivery.drawer_severity(salience.priority) == "info"
    end

    test "idle (went quiet): needs_you + notify-eligible at floor; chrome labels" do
      salience =
        Salience.compute(%{
          agent_states: [],
          quiet?: true,
          lifecycle_status: :other
        })

      assert salience.signal == :idle
      assert salience.rank == 400
      assert Delivery.push_eligible?(salience)
      assert Delivery.session_needs_you?(salience)
      assert Delivery.session_classification(salience) == %{section: :needs_you, reason: :idle}
      assert Delivery.session_reason_urgency(:idle) == 2

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
  end
end
