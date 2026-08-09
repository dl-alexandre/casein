defmodule Casein.Terminals.DoneAgentWindowsTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.DoneAgentWindows
  alias Casein.Terminals.WindowTrash

  @session "casein_alpha_u-dev"
  @now ~U[2026-08-08 12:00:00Z]
  @grace 120

  setup do
    WindowTrash.__reset__()
    :ok
  end

  describe "close policy" do
    test "closes a window whose agent reported done and settled" do
      assert closable?(window(), reports(state: :done, age: 300))
    end

    test "a fresh done report is not closed — it may be one turn of many" do
      # An agent that reports done and immediately starts the next turn must not
      # have its window taken away underneath it.
      refute closable?(window(), reports(state: :done, age: 5))
      refute closable?(window(), reports(state: :done, age: @grace - 1))
      assert closable?(window(), reports(state: :done, age: @grace))
    end

    test "idle never closes a window, however old" do
      # :idle is reachable from the title heuristic alone (a `ready` spinner, or
      # a stale `working` report downgraded). An agent waiting at a permission
      # prompt reads as idle without ever having finished — closing on it would
      # take the window away from an agent that is waiting on the operator.
      refute closable?(window(agent_state: :idle), reports(state: :idle, age: 9_000))
    end

    test "no other agent state closes a window" do
      for state <- [:working, :blocked, :errored, :stalled, :unknown] do
        refute closable?(window(agent_state: state), reports(state: state, age: 9_000)),
               "expected #{inspect(state)} not to be closable"
      end
    end

    test "a done report overridden by a live working spinner does not close" do
      # The enriched window carries the reconciled verdict; if the spinner won,
      # the agent is going again regardless of the standing report.
      refute closable?(window(agent_state: :working), reports(state: :done, age: 9_000))
    end

    test "a state with no underlying done report does not close" do
      # Belt and braces: reconciled :done must be backed by a real report, so a
      # future heuristic that could synthesise :done still cannot close windows.
      refute closable?(window(), %{})
      refute closable?(window(), reports(state: :working, age: 9_000))
    end
  end

  describe "window safety" do
    test "never closes the active window" do
      refute closable?(window(active: true), reports(state: :done, age: 9_000))
    end

    test "never touches a foreign session" do
      refute closable?("other_session", window(), reports(state: :done, age: 9_000))
    end

    test "never closes a window already pending in the trash" do
      {:ok, _} = WindowTrash.trash(@session, "@1", "agent")
      refute closable?(window(), reports(state: :done, age: 9_000))
    end

    test "a non-agent pane reporting done does not close the window" do
      pane = pane(role: "shell", agent_state: :done)
      refute closable?(window(panes: [pane]), reports(state: :done, age: 9_000))
    end

    test "a sibling pane still working keeps the window" do
      panes = [pane(), pane(id: "%2", role: "shell", agent_state: :working)]
      refute closable?(window(panes: panes), reports(state: :done, age: 9_000))
    end

    test "a sibling pane running real work keeps the window" do
      # The agent finished but someone is mid-build/editor/ssh in the same
      # window — that window is still a workspace.
      for cmd <- ~w(vim nvim ssh mix make cargo psql less) do
        panes = [pane(), pane(id: "%2", role: "shell", current_command: cmd)]

        refute closable?(window(panes: panes), reports(state: :done, age: 9_000)),
               "expected a pane running #{cmd} to keep the window open"
      end
    end

    test "shells and finished agent runtimes do not keep the window" do
      for cmd <- ~w(bash zsh claude grok codex opencode) do
        panes = [pane(), pane(id: "%2", role: "shell", current_command: cmd)]

        assert closable?(window(panes: panes), reports(state: :done, age: 9_000)),
               "expected a pane running #{cmd} not to block the close"
      end
    end

    test "a window with no panes is never closable" do
      refute closable?(window(panes: []), reports(state: :done, age: 9_000))
    end

    test "an unknown foreground command keeps the window" do
      # Fail safe: if we cannot tell what a pane is running, leave it alone.
      panes = [pane(), pane(id: "%2", role: "shell", current_command: nil)]
      refute closable?(window(panes: panes), reports(state: :done, age: 9_000))
    end
  end

  describe "soft close, not kill" do
    test "closing routes through WindowTrash so it stays undoable" do
      {:ok, _} = WindowTrash.trash(@session, "@7", "agent-done")

      assert WindowTrash.pending?(@session, "@7")
      # The window is hidden from viewers but tmux is untouched until the timer
      # fires, and any viewer can take it back.
      assert {:ok, _} = WindowTrash.restore(@session, "@7")
      refute WindowTrash.pending?(@session, "@7")
    end
  end

  describe "off by default" do
    test "no sweep interval is configured, so the sweep never runs on its own" do
      # Closing someone's window is not a behaviour to enable silently. The
      # process joins the supervision tree but stays inert until an operator
      # sets an interval.
      assert Application.get_env(:casein, :done_agent_window_sweep_ms) == nil
    end

    test "it runs in the supervision tree but sweeps nothing" do
      # Already started by Casein.Supervision.Terminals — assert on that
      # instance rather than starting a second one under the same name.
      pid = Process.whereis(DoneAgentWindows)
      assert is_pid(pid) and Process.alive?(pid)

      # Inert: a dry run answers empty rather than raising, and with no interval
      # configured no :sweep is ever scheduled.
      assert DoneAgentWindows.dry_run_now() == []
      assert :sys.get_state(pid).interval == nil
    end

    test "grace period defaults to two minutes" do
      assert DoneAgentWindows.grace_seconds() == 120
    end

    test "a bogus configured grace falls back to the default" do
      original = Application.get_env(:casein, :done_agent_window_grace_seconds)
      on_exit(fn -> restore_env(:done_agent_window_grace_seconds, original) end)

      Application.put_env(:casein, :done_agent_window_grace_seconds, "soon")
      assert DoneAgentWindows.grace_seconds() == 120

      Application.put_env(:casein, :done_agent_window_grace_seconds, 300)
      assert DoneAgentWindows.grace_seconds() == 300
    end
  end

  ## Helpers

  defp restore_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_env(key, value), do: Application.put_env(:casein, key, value)

  defp closable?(window, reports), do: closable?(@session, window, reports)

  defp closable?(session, window, reports),
    do: DoneAgentWindows.closable?(session, window, @now, @grace, reports)

  defp window(opts \\ []) do
    panes = Keyword.get(opts, :panes, [pane(agent_state: Keyword.get(opts, :agent_state, :done))])

    %{
      id: "@1",
      name: "agent",
      active: Keyword.get(opts, :active, false),
      pane_list: panes
    }
  end

  defp pane(opts \\ []) do
    %{
      id: Keyword.get(opts, :id, "%1"),
      role: Keyword.get(opts, :role, "agent"),
      agent_state: Keyword.get(opts, :agent_state, :done),
      current_command: Keyword.get(opts, :current_command, "claude")
    }
  end

  defp reports(opts) do
    %{
      "%1" => %{
        state: Keyword.fetch!(opts, :state),
        message: nil,
        source: :mcp,
        tool: nil,
        workspace_id: "ws-1",
        transcript_path: nil,
        agent_session_id: nil,
        reported_at: DateTime.add(@now, -Keyword.fetch!(opts, :age), :second)
      }
    }
  end
end
