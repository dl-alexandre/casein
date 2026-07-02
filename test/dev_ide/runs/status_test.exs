defmodule DevIDE.Runs.StatusTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Runs.Status
  alias DevIDE.Audit.Event

  describe "normalize/1" do
    test "converts atoms to strings" do
      assert Status.normalize(:running) == "running"
      assert Status.normalize(:succeeded) == "succeeded"
      assert Status.normalize(:failed) == "failed"
      assert Status.normalize(:timed_out) == "timed_out"
    end

    test "passes strings through unchanged" do
      assert Status.normalize("running") == "running"
      assert Status.normalize("succeeded") == "succeeded"
      assert Status.normalize("denied") == "denied"
    end

    test "returns unknown for nil and other values" do
      assert Status.normalize(nil) == "unknown"
      assert Status.normalize(42) == "unknown"
    end
  end

  describe "terminal?/1" do
    test "terminal statuses" do
      for s <- [
            :succeeded,
            :failed,
            :timed_out,
            "denied",
            "approval_denied",
            "expired",
            "abandoned"
          ] do
        assert Status.terminal?(s), "expected #{inspect(s)} to be terminal"
      end
    end

    test "non-terminal statuses" do
      for s <- [:running, :requested, "queued", "claimed", "approval_requested"] do
        refute Status.terminal?(s), "expected #{inspect(s)} to not be terminal"
      end
    end
  end

  describe "failed?/1" do
    test "failure statuses" do
      for s <- [:failed, :timed_out, "denied", "approval_denied", "expired", "abandoned"] do
        assert Status.failed?(s), "expected #{inspect(s)} to be failed"
      end
    end

    test "non-failure statuses" do
      for s <- [:succeeded, :running, :requested, "queued", "claimed"] do
        refute Status.failed?(s), "expected #{inspect(s)} to not be failed"
      end
    end
  end

  describe "blocked?/1" do
    test "blocked statuses" do
      assert blocked?("denied")
      assert blocked?("approval_denied")
      assert blocked?(:denied)
      assert blocked?(:approval_denied)
    end

    test "non-blocked statuses" do
      refute blocked?(:failed)
      refute blocked?(:succeeded)
      refute blocked?(:running)
      refute blocked?(:timed_out)
      refute blocked?("expired")
    end
  end

  describe "in_progress?/1" do
    test "in-progress statuses" do
      for s <- [:running, :requested, "queued", "claimed", "approval_requested"] do
        assert Status.in_progress?(s), "expected #{inspect(s)} to be in_progress"
      end
    end

    test "non-in-progress statuses" do
      for s <- [:succeeded, :failed, :timed_out, "denied", "expired", "abandoned"] do
        refute Status.in_progress?(s), "expected #{inspect(s)} to not be in_progress"
      end
    end
  end

  describe "retryable?/2" do
    test "retryable when terminal, not blocked, and policy allows" do
      summary = %{command_id: "test", status: "failed"}
      decision_fun = fn _ -> DevIDE.Policy.Decision.allow(:run_command, :manual) end
      assert Status.retryable?(summary, decision_fun)
    end

    test "not retryable when blocked" do
      summary = %{command_id: "test", status: "denied"}
      decision_fun = fn _ -> DevIDE.Policy.Decision.allow(:run_command, :manual) end
      refute Status.retryable?(summary, decision_fun)
    end

    test "not retryable when non-terminal" do
      summary = %{command_id: "test", status: "running"}
      decision_fun = fn _ -> DevIDE.Policy.Decision.allow(:run_command, :manual) end
      refute Status.retryable?(summary, decision_fun)
    end

    test "not retryable when policy denies" do
      summary = %{command_id: "test", status: "failed"}
      decision_fun = fn _ -> DevIDE.Policy.Decision.deny(:run_command, :manual, :not_allowed) end
      refute Status.retryable?(summary, decision_fun)
    end

    test "not retryable without command_id" do
      summary = %{status: "failed"}
      decision_fun = fn _ -> DevIDE.Policy.Decision.allow(:run_command, :manual) end
      refute Status.retryable?(summary, decision_fun)
    end
  end

  describe "failure_reason/2" do
    test "blocked run extracts denial reason from timeline" do
      summary = %{status: "denied"}

      timeline = [
        %Event{
          id: Ecto.UUID.generate(),
          action: "run.command_denied",
          reason: :not_allowed,
          inserted_at: DateTime.utc_now(),
          metadata: %{}
        }
      ]

      assert Status.failure_reason(summary, timeline) == "not_allowed"
    end

    test "failed run with exit code" do
      summary = %{status: "failed", exit_code: 1}
      assert Status.failure_reason(summary, []) == "exit 1"
    end

    test "failed run without exit code" do
      summary = %{status: "failed"}
      assert Status.failure_reason(summary, []) == "failed"
    end

    test "timed out" do
      summary = %{status: "timed_out"}
      assert Status.failure_reason(summary, []) == "timed out"
    end

    test "expired" do
      summary = %{status: "expired"}
      assert Status.failure_reason(summary, []) == "runner lease expired"
    end

    test "abandoned" do
      summary = %{status: "abandoned"}
      assert Status.failure_reason(summary, []) == "abandoned"
    end

    test "succeeded returns nil" do
      summary = %{status: "succeeded"}
      assert Status.failure_reason(summary, []) == nil
    end

    test "running returns nil" do
      summary = %{status: "running"}
      assert Status.failure_reason(summary, []) == nil
    end
  end

  describe "status_class/1" do
    test "maps in-progress statuses to :running" do
      for s <- [:running, :requested, "queued", "claimed", "approval_requested"] do
        assert Status.status_class(s) == :running
      end
    end

    test "maps succeeded to :succeeded" do
      assert Status.status_class(:succeeded) == :succeeded
      assert Status.status_class("succeeded") == :succeeded
    end

    test "maps failure statuses to :failed" do
      for s <- [:failed, "denied", "approval_denied", "abandoned"] do
        assert Status.status_class(s) == :failed
      end
    end

    test "maps timeout/expired to :timed_out" do
      assert Status.status_class(:timed_out) == :timed_out
      assert Status.status_class("expired") == :timed_out
    end

    test "maps unknown to :unknown" do
      assert Status.status_class(nil) == :unknown
      assert Status.status_class("garbage") == :unknown
    end
  end

  defp blocked?(status) do
    Status.blocked?(status)
  end
end
