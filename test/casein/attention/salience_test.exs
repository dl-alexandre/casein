defmodule Casein.Attention.SalienceTest do
  use ExUnit.Case, async: true

  alias Casein.Attention.{Delivery, Salience, Signal}

  describe "compute/1 card path" do
    test "human blocked outranks failure and working" do
      blocked =
        Salience.compute(%{
          card_type: "clarification",
          status: "open",
          resume_state: "needs_attention",
          resume_phase: "waiting",
          availability: "live"
        })

      failed =
        Salience.compute(%{
          status: "failed",
          resume_state: "failed",
          availability: "live"
        })

      working =
        Salience.compute(%{
          resume_state: "working",
          availability: "live"
        })

      assert blocked.signal == :agent_blocked
      assert blocked.priority == "critical"
      assert blocked.rank == 700
      assert blocked.reason_code == "human_blocked"
      assert blocked.notify

      assert failed.rank == 560
      assert working.rank == 120
      assert blocked.rank > failed.rank
      assert failed.rank > working.rank
    end

    test "review requested is critical and notify-eligible" do
      salience =
        Salience.compute(%{
          transition_action: "run.approval_requested",
          resume_state: "needs_attention",
          resume_phase: "review",
          availability: "live"
        })

      assert salience.signal == :approval_pending
      assert salience.rank == 680
      assert salience.reason_code == "review_requested"
      assert salience.required_decision == "Review"
      assert salience.notify
      assert Delivery.notify_eligible?(salience)
    end

    test "gate failure uses checks_failed reason without a second ranker" do
      salience =
        Salience.compute(%{
          transition_action: "gate.failed",
          availability: "live"
        })

      assert salience.signal == :checks_failed
      assert salience.rank == 560
      assert salience.reason_code == "checks_failed"
    end

    test "working does not notify" do
      salience =
        Salience.compute(%{
          resume_state: "working",
          availability: "live"
        })

      assert salience.signal == :working
      assert salience.rank == 120
      refute salience.notify
      refute Delivery.notify_eligible?(salience)
    end

    test "facts_from_card feeds compute identically to direct facts" do
      card = %{
        type: "clarification",
        status: "open",
        meta: %{source: "agent.blocked", reason: "blocked on human"}
      }

      resume = %{state: "needs_attention", phase: "waiting", availability: "live"}
      latest = %{action: "agent.blocked", state: "needs_attention", phase: "waiting"}

      assert Salience.compute(Salience.facts_from_card(card, resume, latest)).reason_code ==
               "human_blocked"
    end
  end

  describe "compute/1 session path" do
    test "blocked and stalled agent states need you" do
      for state <- [:blocked, :errored, :stalled, "blocked"] do
        end_to_end =
          %{windows: [%{agent_state: state}]}
          |> Salience.facts_from_session()
          |> Salience.compute()

        assert end_to_end.signal == :agent_blocked
        assert end_to_end.rank == 700

        assert Delivery.session_classification(end_to_end) == %{
                 section: :needs_you,
                 reason: :blocked
               }
      end
    end

    test "quiet window projects to signal :idle (post-#696 vocabulary)" do
      salience =
        %{windows: [%{quiet: true}]}
        |> Salience.facts_from_session()
        |> Salience.compute()

      assert salience.signal == :idle
      assert salience.reason_code == "idle"
      assert Delivery.session_classification(salience) == %{section: :needs_you, reason: :idle}
    end

    test "done agent is needs_you completed" do
      salience =
        %{windows: [%{agent_state: :done}]}
        |> Salience.facts_from_session()
        |> Salience.compute()

      assert salience.signal == :run_completed

      assert Delivery.session_classification(salience) == %{
               section: :needs_you,
               reason: :completed
             }
    end

    test "lifecycle error without blocked window is needs_you error" do
      salience =
        %{status: :error, windows: [%{}]}
        |> Salience.facts_from_session()
        |> Salience.compute()

      assert salience.signal == :run_failed
      assert Delivery.session_classification(salience) == %{section: :needs_you, reason: :error}
    end

    test "working and ordinary shells partition correctly" do
      working =
        %{windows: [%{agent_state: :working}]}
        |> Salience.facts_from_session()
        |> Salience.compute()

      recent =
        %{windows: [%{}]}
        |> Salience.facts_from_session()
        |> Salience.compute()

      assert Delivery.session_classification(working) == %{section: :working, reason: :working}
      assert Delivery.session_classification(recent) == %{section: :recent, reason: :recent}
    end
  end

  describe "Signal" do
    test "meaningful actions match the former inbox allowlist" do
      assert Signal.meaningful_action?("agent.blocked")
      assert Signal.from_event_action("agent.blocked") == :agent_blocked
      assert Signal.from_event_action("run.failed") == :run_failed
      refute Signal.meaningful_action?("noise.event")
    end
  end
end
