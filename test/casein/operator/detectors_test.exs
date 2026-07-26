defmodule Casein.Operator.DetectorsTest do
  use Casein.TestCase, async: true

  alias Casein.Operator.Detectors

  @now ~U[2026-07-16 12:00:00Z]

  defp entry(state, ago_s, message \\ nil) do
    %{
      state: state,
      message: message,
      source: :mcp,
      tool: nil,
      workspace_id: "ws-det",
      transcript_path: nil,
      reported_at: DateTime.add(@now, -ago_s, :second)
    }
  end

  describe "blocked_too_long/3" do
    test "flags blocked entries older than the threshold, with redacted evidence" do
      entries = %{
        {"casein_a_agent", "%1"} => entry(:blocked, 700, "token=sk-live-1234567890abcdef"),
        {"casein_a_agent", "%2"} => entry(:blocked, 30),
        {"casein_a_agent", "%3"} => entry(:working, 700)
      }

      assert [risk] = Detectors.blocked_too_long(entries, @now, 600)
      assert risk.id == :blocked_too_long
      assert risk.severity == :critical
      assert risk.subject == "casein_a_agent %1"
      assert risk.detected_at == @now
      assert risk.evidence.blocked_for_s == 700
      assert risk.evidence.message =~ "[REDACTED]"
      refute risk.evidence.message =~ "sk-live"
    end

    test "ignores entries without a reported_at and empty maps" do
      assert Detectors.blocked_too_long(%{}, @now, 600) == []

      entries = %{{"s", "%1"} => %{state: :blocked, reported_at: nil}}
      assert Detectors.blocked_too_long(entries, @now, 600) == []
    end
  end

  describe "working_no_output/4" do
    setup do
      digest = %{
        sessions: [
          %{
            sid: "sid-1",
            tmux_session: "casein_a_agent",
            panes: [
              %{id: "%1", agent_state: :working, task_summary: "refactor"},
              %{id: "%2", agent_state: :idle}
            ]
          },
          %{
            sid: "sid-2",
            tmux_session: "casein_a_shell",
            panes: [%{id: "%3", agent_state: :working}]
          }
        ]
      }

      {:ok, digest: digest}
    end

    test "flags working panes in sessions silent past the threshold", %{digest: digest} do
      last_output_at = %{
        "sid-1" => DateTime.add(@now, -400, :second),
        "sid-2" => DateTime.add(@now, -10, :second)
      }

      assert [risk] = Detectors.working_no_output(digest, last_output_at, @now, 300)
      assert risk.id == :working_no_output
      assert risk.severity == :warn
      assert risk.subject == "casein_a_agent %1"
      assert risk.evidence.sid == "sid-1"
      assert risk.evidence.silent_for_s == 400
      assert risk.evidence.task_summary == "refactor"
    end

    test "sessions with no output baseline are never judged", %{digest: digest} do
      assert Detectors.working_no_output(digest, %{}, @now, 300) == []
    end

    test "a nil digest yields no risks" do
      assert Detectors.working_no_output(nil, %{"sid-1" => @now}, @now, 300) == []
    end
  end

  describe "leaked_worktree/3" do
    test "surfaces only alarms attributed to the workspace" do
      alarms = [
        %{
          path: "/tmp/wt-leak",
          workspace_id: "ws-det",
          branch: "agent/claude/x",
          dirty: true,
          age_seconds: 90_000,
          reasons: ["dirty", "no_process", "stale"]
        },
        %{path: "/tmp/wt-other", workspace_id: "ws-other"},
        %{path: "/tmp/wt-unknown", workspace_id: nil}
      ]

      assert [risk] = Detectors.leaked_worktree(alarms, "ws-det", @now)
      assert risk.id == :leaked_worktree
      assert risk.severity == :warn
      assert risk.subject == "/tmp/wt-leak"
      assert risk.detected_at == @now
      assert risk.evidence.reasons == ["dirty", "no_process", "stale"]
    end

    test "an empty sweep yields no risks" do
      assert Detectors.leaked_worktree([], "ws-det", @now) == []
    end
  end
end
