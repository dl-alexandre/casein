defmodule DevIdeWeb.WorkspaceLive.Show.RunPanelTest do
  use DevIDE.TestCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DevIdeWeb.WorkspaceLive.Show.RunPanel

  # Base assigns covering every key the run_panel/1 template references.
  # Individual tests override pieces to drive specific branches.
  defp base_assigns do
    %{
      host_loc: {:ok, {:local, "/tmp/ws"}},
      active_run: nil,
      run_ledger: [],
      selected_run_id: nil,
      selected_run_timeline: [],
      selected_run_summary: nil,
      selected_run_failure_reason: nil,
      selected_run_can_retry: false,
      selected_run_artifacts: []
    }
  end

  defp render_panel(overrides) do
    assigns = Map.merge(base_assigns(), Map.new(overrides))

    rendered_to_string(~H"""
    <RunPanel.run_panel
      host_loc={@host_loc}
      active_run={@active_run}
      run_ledger={@run_ledger}
      selected_run_id={@selected_run_id}
      selected_run_timeline={@selected_run_timeline}
      selected_run_summary={@selected_run_summary}
      selected_run_failure_reason={@selected_run_failure_reason}
      selected_run_can_retry={@selected_run_can_retry}
      selected_run_artifacts={@selected_run_artifacts}
    />
    """)
  end

  describe "run_panel/1 host_loc gate" do
    test "renders the unavailable message when host_loc is not {:ok, _}" do
      html = render_panel(host_loc: {:error, :missing_path})

      assert html =~ "Cannot run commands: workspace path unavailable."
      # The command buttons / ledger must not render in the error branch.
      refute html =~ "Run ledger"
    end

    test "renders command buttons and ledger when host_loc is {:ok, _}" do
      html = render_panel(host_loc: {:ok, {:local, "/tmp/ws"}})

      assert html =~ ~s(phx-click="run:start")
      assert html =~ "Run ledger"
      assert html =~ "Timeline"
      # run_button_label/2: mix-prefixed argv -> "mix <id>", others -> id
      assert html =~ "mix compile"
      assert html =~ "mix test"
      assert html =~ "claude"
    end
  end

  describe "run_panel/1 active_run states" do
    test "shows 'No runs yet.' when there is no active run" do
      html = render_panel(active_run: nil)

      assert html =~ "No runs yet."
      # No cancel button without a running run.
      refute html =~ ~s(phx-click="run:cancel")
    end

    test "renders a running active run with cancel button and disabled start buttons" do
      run = %{
        status: :running,
        argv: ["mix", "test"],
        exit_code: nil,
        started_at: nil,
        finished_at: nil,
        buffer: "compiling project..."
      }

      html = render_panel(active_run: run)

      # cancel button only present while running
      assert html =~ ~s(phx-click="run:cancel")
      assert html =~ "cancel"
      # start buttons disabled while running
      assert html =~ "disabled"
      # argv joined and status rendered with the running class
      assert html =~ "mix test"
      assert html =~ "running"
      assert html =~ "text-amber-700"
      assert html =~ "compiling project..."
      # exit/started/finished spans omitted when nil
      refute html =~ "exit="
      refute html =~ "started "
      refute html =~ "finished "
    end

    test "renders a finished succeeded run with exit code, timestamps and buffer" do
      started = ~U[2026-06-24 10:00:00Z]
      finished = ~U[2026-06-24 10:00:05Z]

      run = %{
        status: :succeeded,
        argv: ["mix", "format"],
        exit_code: 0,
        started_at: started,
        finished_at: finished,
        buffer: "all formatted"
      }

      html = render_panel(active_run: run)

      assert html =~ "succeeded"
      assert html =~ "text-green-700"
      assert html =~ "exit=0"
      assert html =~ "started #{DateTime.to_string(started)}"
      assert html =~ "finished #{DateTime.to_string(finished)}"
      assert html =~ "all formatted"
      # not running -> no cancel
      refute html =~ ~s(phx-click="run:cancel")
    end

    test "renders a failed run status class" do
      run = %{
        status: :failed,
        argv: ["mix", "compile"],
        exit_code: 1,
        started_at: nil,
        finished_at: nil,
        buffer: ""
      }

      html = render_panel(active_run: run)

      assert html =~ "failed"
      assert html =~ "text-red-700"
      assert html =~ "exit=1"
    end

    test "renders timed_out run status class (purple)" do
      run = %{
        status: :timed_out,
        argv: ["mix", "test"],
        exit_code: nil,
        started_at: nil,
        finished_at: nil,
        buffer: ""
      }

      html = render_panel(active_run: run)

      assert html =~ "timed_out"
      assert html =~ "text-purple-700"
    end
  end

  describe "run_panel/1 run ledger" do
    test "renders the empty ledger placeholder" do
      html = render_panel(run_ledger: [])

      assert html =~ "run-ledger-empty"
      assert html =~ "No runs recorded."
      assert html =~ "0 runs"
    end

    test "renders ledger rows with command id, status, protocol and optional fields" do
      ledger = [
        %{
          id: "run-abc-1",
          command_id: "compile",
          status: "succeeded",
          protocol: "exec",
          assignment_id: "assign-9",
          finished_at: "2026-06-24T10:00:05Z"
        },
        # second row exercises fallbacks: no command_id -> safe_action_id,
        # no protocol -> "ledger" default, no assignment/finished spans.
        %{
          id: "run def 2",
          safe_action_id: "format",
          status: "running"
        }
      ]

      html = render_panel(run_ledger: ledger, selected_run_id: "run-abc-1")

      assert html =~ "2 runs"
      assert html =~ "compile"
      assert html =~ "succeeded"
      assert html =~ "exec"
      assert html =~ "assignment=assign-9"
      assert html =~ "2026-06-24T10:00:05Z"
      # safe_action_id fallback and default protocol "ledger"
      assert html =~ "format"
      assert html =~ "ledger"
      assert html =~ "running"
      # dom_fragment sanitizes ids for the element id (spaces -> dashes)
      assert html =~ "run-ledger-run-run-abc-1"
      assert html =~ "run-ledger-run-run-def-2"
      # selected row highlight class
      assert html =~ "border-zinc-900 bg-zinc-50"
    end

    test "renders status fallback when a ledger row has no status" do
      ledger = [%{id: "r1"}]

      html = render_panel(run_ledger: ledger)

      # Map.get(r, :status, "unknown") and the id used as the label fallback.
      assert html =~ "unknown"
      assert html =~ "r1"
    end
  end

  describe "run_panel/1 timeline and summary" do
    test "renders the empty timeline placeholder" do
      html = render_panel(selected_run_timeline: [])

      assert html =~ "run-ledger-timeline-empty"
      assert html =~ "Select a run to inspect its canonical events."
    end

    test "shows selected_run_id in the timeline header" do
      html = render_panel(selected_run_id: "run-xyz")

      assert html =~ "run-xyz"
    end

    test "renders timeline events with varied decision/action styling" do
      timeline = [
        %{
          id: "evt-1",
          inserted_at: ~U[2026-06-24 09:15:30Z],
          action: "run.command_allowed",
          decision: :allow,
          target_ref: "compile",
          reason: nil,
          metadata: %{"noun" => "command"}
        },
        %{
          id: "evt 2",
          inserted_at: ~U[2026-06-24 09:16:00Z],
          action: "run.command_denied",
          decision: :deny,
          target_ref: "rm-rf",
          reason: :not_allowlisted,
          metadata: %{}
        },
        %{
          id: "evt-3",
          inserted_at: ~U[2026-06-24 09:17:00Z],
          action: "workspace.mode_set",
          decision: nil,
          target_ref: "",
          reason: nil,
          metadata: nil
        }
      ]

      html =
        render_panel(
          selected_run_timeline: timeline,
          selected_run_summary: nil
        )

      # ordered timeline container
      assert html =~ "run-ledger-timeline"
      # dom_fragment on event ids
      assert html =~ "run-ledger-event-evt-1"
      assert html =~ "run-ledger-event-evt-2"
      # actions rendered
      assert html =~ "run.command_allowed"
      assert html =~ "run.command_denied"
      assert html =~ "workspace.mode_set"
      # decision dot/verb classes
      assert html =~ "bg-green-600"
      assert html =~ "text-green-700"
      assert html =~ "bg-red-600"
      assert html =~ "text-red-700"
      assert html =~ "bg-amber-500"
      assert html =~ "text-amber-700"
      # ledger_event_noun: metadata "noun" -> "command", missing -> "event"
      assert html =~ "command"
      assert html =~ "event"
      # audit_detail: action · target_ref · reason
      assert html =~ "run.command_allowed · compile"
      assert html =~ "run.command_denied · rm-rf · not_allowlisted"
      # strftime time formatting
      assert html =~ "09:15:30"
    end

    test "renders a summary dl without failure surface for a succeeded run" do
      summary = %{
        status: "succeeded",
        command_id: "compile",
        assignment_id: "assign-7"
      }

      timeline = [
        %{
          id: "e1",
          inserted_at: ~U[2026-06-24 09:00:00Z],
          action: "run.completed",
          target_ref: "cmd-1",
          reason: nil,
          metadata: %{}
        }
      ]

      html =
        render_panel(
          selected_run_timeline: timeline,
          selected_run_summary: summary
        )

      assert html =~ "run-ledger-summary"
      assert html =~ "status"
      assert html =~ "succeeded"
      assert html =~ "command"
      assert html =~ "compile"
      assert html =~ "assignment"
      assert html =~ "assign-7"
      # succeeded is not failed -> no failure surface
      refute html =~ "run-failure-surface"
    end

    test "renders summary with command fallback and no assignment row" do
      summary = %{
        status: "running",
        safe_action_id: "format"
      }

      timeline = [
        %{
          id: "e1",
          inserted_at: ~U[2026-06-24 09:00:00Z],
          action: "run.started",
          target_ref: "cmd-1",
          reason: nil,
          metadata: %{}
        }
      ]

      html =
        render_panel(
          selected_run_timeline: timeline,
          selected_run_summary: summary
        )

      assert html =~ "run-ledger-summary"
      # command_id missing -> safe_action_id fallback
      assert html =~ "format"
      # no assignment_id -> assignment row omitted
      refute html =~ "assignment</dt>"
    end

    test "renders the failure surface with reason and retry button for a failed run" do
      summary = %{
        status: "failed",
        command_id: "test",
        exit_code: 1
      }

      timeline = [
        %{
          id: "e1",
          inserted_at: ~U[2026-06-24 09:00:00Z],
          action: "run.failed",
          target_ref: "cmd-1",
          reason: nil,
          metadata: %{}
        }
      ]

      html =
        render_panel(
          selected_run_timeline: timeline,
          selected_run_summary: summary,
          selected_run_failure_reason: "exit 1",
          selected_run_can_retry: true
        )

      assert html =~ "run-failure-surface"
      assert html =~ "Failed"
      assert html =~ "exit 1"
      # retry button targets command_id
      assert html =~ "run-retry-btn"
      assert html =~ ~s(phx-value-id="test")
      assert html =~ "Retry"
    end

    test "renders the failure surface without retry when can_retry is false" do
      summary = %{status: "denied", command_id: "rm"}

      timeline = [
        %{
          id: "e1",
          inserted_at: ~U[2026-06-24 09:00:00Z],
          action: "run.denied",
          target_ref: "cmd-1",
          reason: nil,
          metadata: %{}
        }
      ]

      html =
        render_panel(
          selected_run_timeline: timeline,
          selected_run_summary: summary,
          selected_run_failure_reason: nil,
          selected_run_can_retry: false
        )

      # denied is a failed? status -> failure surface present
      assert html =~ "run-failure-surface"
      assert html =~ "Failed"
      # no reason span, no retry button
      refute html =~ "run-retry-btn"
    end
  end

  describe "run_panel/1 artifacts" do
    test "renders the empty artifacts placeholder when timeline is present but no artifacts" do
      timeline = [
        %{
          id: "e1",
          inserted_at: ~U[2026-06-24 09:00:00Z],
          action: "run.started",
          target_ref: "cmd-1",
          reason: nil,
          metadata: %{}
        }
      ]

      html =
        render_panel(
          selected_run_timeline: timeline,
          selected_run_artifacts: []
        )

      assert html =~ "run-ledger-artifacts"
      assert html =~ "No artifacts recorded for this run."
    end

    test "renders run_artifact children for non-empty artifacts" do
      timeline = [
        %{
          id: "e1",
          inserted_at: ~U[2026-06-24 09:00:00Z],
          action: "run.completed",
          target_ref: "cmd-1",
          reason: nil,
          metadata: %{}
        }
      ]

      artifacts = [
        %{
          type: "command_output",
          command_id: "compile",
          status: "succeeded",
          exit_code: 0,
          output: "Compiling 3 files",
          output_truncated: false
        }
      ]

      html =
        render_panel(
          selected_run_timeline: timeline,
          selected_run_artifacts: artifacts
        )

      assert html =~ "run-artifact-command-output"
      assert html =~ "Compiling 3 files"
    end
  end

  describe "run_artifact/1" do
    defp render_artifact(artifact) do
      assigns = %{artifact: artifact}

      rendered_to_string(~H"""
      <RunPanel.run_artifact artifact={@artifact} />
      """)
    end

    test "renders a command_output artifact with exit code and truncated marker" do
      html =
        render_artifact(%{
          type: "command_output",
          command_id: "test",
          status: "failed",
          exit_code: 2,
          output: "boom\nstacktrace",
          output_truncated: true
        })

      assert html =~ "run-artifact-command-output"
      assert html =~ "command output"
      assert html =~ "test"
      assert html =~ "failed"
      assert html =~ "exit=2"
      assert html =~ "truncated"
      assert html =~ "boom"
    end

    test "renders a command_output artifact without exit code or truncated marker" do
      html =
        render_artifact(%{
          type: "command_output",
          command_id: "format",
          status: "succeeded",
          output: "ok"
        })

      assert html =~ "run-artifact-command-output"
      assert html =~ "format"
      assert html =~ "ok"
      refute html =~ "exit="
      refute html =~ "truncated"
    end

    test "renders the unknown-artifact fallback for an unrecognized type" do
      html = render_artifact(%{type: "screenshot"})

      assert html =~ "Unknown artifact."
    end

    test "renders the unknown-artifact fallback when type is missing" do
      html = render_artifact(%{})

      assert html =~ "Unknown artifact."
    end
  end
end
