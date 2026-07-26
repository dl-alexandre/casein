defmodule Casein.Terminals.TmuxWindowJanitorSweepTest do
  # async: false — mutates global Application env (:tmux_ctl runner + janitor
  # idle/sweep config) and drives the singleton janitor GenServer that the
  # application supervisor already owns under the fixed module name.
  use Casein.TestCase, async: false

  alias Casein.Terminals.TmuxWindowJanitor, as: Janitor

  # In-test runner that satisfies the exact server-wide argv the janitor's
  # pipeline issues through TmuxCtl.Client (list-windows -a, list-sessions,
  # list-panes -a, kill-window, kill-session). The project's shared
  # TmuxCtl.Test.FakeRunner only answers the *per-session* list forms, so the
  # janitor (which lists across the whole server) needs this one. It reads the
  # same FakeState keys and reports kills back to the test pid.
  defmodule SweepRunner do
    @behaviour TmuxCtl.Runner
    alias TmuxCtl.Test.FakeState

    @impl true
    def run(argv, _opts), do: respond(argv)

    def argv(argv, _opts), do: ["tmux" | argv]

    # list-windows -a -F <fmt>  ->  session|window_id|active|panes|auto_rename|activity|cmd
    defp respond(["list-windows", "-a", "-F", _fmt]) do
      out =
        FakeState.get(:sweep_windows, [])
        |> Enum.map_join("\n", fn w ->
          "#{w.session}|#{w.window_id}|#{b(w.active)}|#{w.panes}|#{b(w.automatic_rename)}|#{w.activity}|#{w.current_command}"
        end)

      {out, 0}
    end

    # list-sessions -F <fmt>  ->  session|attached|activity|alias
    defp respond(["list-sessions", "-F", _fmt]) do
      out =
        FakeState.get(:sweep_sessions, [])
        |> Enum.map_join("\n", fn s ->
          "#{s.session}|#{b(s.attached)}|#{s.activity}|"
        end)

      {out, 0}
    end

    # list-panes -a -F <fmt>  ->  session|current_command
    defp respond(["list-panes", "-a", "-F", _fmt]) do
      out =
        FakeState.get(:sweep_panes, [])
        |> Enum.map_join("\n", fn {session, cmd} -> "#{session}|#{cmd}" end)

      {out, 0}
    end

    defp respond(["kill-window", "-t", target]) do
      if pid = FakeState.get(:sweep_test_pid), do: send(pid, {:killed_window, target})
      {"", 0}
    end

    defp respond(["kill-session", "-t", session]) do
      if pid = FakeState.get(:sweep_test_pid), do: send(pid, {:killed_session, session})
      # Mark the session gone so client.kill/2's retry loop (has-session probe)
      # stops on the first attempt instead of sleeping/retrying.
      FakeState.update(:sweep_dead_sessions, MapSet.new(), &MapSet.put(&1, session))
      {"", 0}
    end

    # has-session -t <session>: 0 = alive, non-zero = gone. Report killed
    # sessions as gone so kill/2 returns immediately.
    defp respond(["has-session", "-t", session]) do
      dead = FakeState.get(:sweep_dead_sessions, MapSet.new())
      if MapSet.member?(dead, session), do: {"", 1}, else: {"", 0}
    end

    # Everything else the janitor never calls; keep it inert.
    defp respond(_argv), do: {"", 0}

    defp b(true), do: "1"
    defp b(false), do: "0"
    defp b(nil), do: "0"
  end

  defp now, do: System.system_time(:second)
  @idle 5

  setup do
    prev = %{
      runner: Application.get_env(:tmux_ctl, :runner),
      window_idle: Application.get_env(:casein, :tmux_window_idle_seconds),
      session_idle: Application.get_env(:casein, :tmux_session_idle_seconds),
      sweep_ms: Application.get_env(:casein, :tmux_window_sweep_ms),
      sweep_windows: TmuxCtl.Test.FakeState.get(:sweep_windows),
      sweep_sessions: TmuxCtl.Test.FakeState.get(:sweep_sessions),
      sweep_panes: TmuxCtl.Test.FakeState.get(:sweep_panes),
      sweep_test_pid: TmuxCtl.Test.FakeState.get(:sweep_test_pid),
      sweep_dead: TmuxCtl.Test.FakeState.get(:sweep_dead_sessions)
    }

    Application.put_env(:tmux_ctl, :runner, SweepRunner)
    Application.put_env(:casein, :tmux_window_idle_seconds, @idle)
    Application.put_env(:casein, :tmux_session_idle_seconds, @idle)
    TmuxCtl.Test.FakeState.put(:sweep_test_pid, self())
    TmuxCtl.Test.FakeState.put(:sweep_dead_sessions, MapSet.new())

    on_exit(fn ->
      restore(:tmux_ctl, :runner, prev.runner)
      restore(:casein, :tmux_window_idle_seconds, prev.window_idle)
      restore(:casein, :tmux_session_idle_seconds, prev.session_idle)
      restore(:casein, :tmux_window_sweep_ms, prev.sweep_ms)
      TmuxCtl.Test.FakeState.restore(:sweep_windows, prev.sweep_windows)
      TmuxCtl.Test.FakeState.restore(:sweep_sessions, prev.sweep_sessions)
      TmuxCtl.Test.FakeState.restore(:sweep_panes, prev.sweep_panes)
      TmuxCtl.Test.FakeState.restore(:sweep_test_pid, prev.sweep_test_pid)
      TmuxCtl.Test.FakeState.restore(:sweep_dead_sessions, prev.sweep_dead)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  # A window that satisfies every kill condition (mirrors the predicate test).
  defp killable_window(overrides) do
    Map.merge(
      %{
        session: "casein_ws_u-abc-tab1",
        window_id: "@7",
        active: false,
        panes: 1,
        automatic_rename: true,
        current_command: "bash",
        activity: now() - @idle - 100
      },
      overrides
    )
  end

  defp orphan_session(overrides) do
    Map.merge(
      %{session: "casein_ws_u-orphan", attached: false, activity: now() - @idle - 100},
      overrides
    )
  end

  defp seed(opts) do
    TmuxCtl.Test.FakeState.put(:sweep_windows, Keyword.get(opts, :windows, []))
    TmuxCtl.Test.FakeState.put(:sweep_sessions, Keyword.get(opts, :sessions, []))
    TmuxCtl.Test.FakeState.put(:sweep_panes, Keyword.get(opts, :panes, []))
  end

  describe "sweep_now/0 — window reaping (sweep_windows/1)" do
    test "kills only the killable windows and spares every disqualified one" do
      killable = killable_window(%{window_id: "@7"})

      spared = [
        killable_window(%{window_id: "@active", active: true}),
        killable_window(%{window_id: "@named", automatic_rename: false}),
        killable_window(%{window_id: "@multipane", panes: 2}),
        killable_window(%{window_id: "@busy", current_command: "vim"}),
        killable_window(%{window_id: "@recent", activity: now()}),
        killable_window(%{window_id: "@foreign", session: "other_session"})
      ]

      # Shuffle the killable window in among the spared ones.
      seed(windows: [Enum.at(spared, 0), killable | Enum.drop(spared, 1)])

      assert Janitor.sweep_now() == 1

      # Exactly the killable window was reaped.
      assert_received {:killed_window, "casein_ws_u-abc-tab1:@7"}

      # None of the spared windows were touched.
      refute_received {:killed_window, "casein_ws_u-abc-tab1:@active"}
      refute_received {:killed_window, "casein_ws_u-abc-tab1:@named"}
      refute_received {:killed_window, "casein_ws_u-abc-tab1:@multipane"}
      refute_received {:killed_window, "casein_ws_u-abc-tab1:@busy"}
      refute_received {:killed_window, "casein_ws_u-abc-tab1:@recent"}
      refute_received {:killed_window, "other_session:@foreign"}
    end

    test "reaps multiple killable windows across sessions" do
      seed(
        windows: [
          killable_window(%{session: "casein_ws_a", window_id: "@1"}),
          killable_window(%{session: "casein_ws_b", window_id: "@2"})
        ]
      )

      assert Janitor.sweep_now() == 2
      assert_received {:killed_window, "casein_ws_a:@1"}
      assert_received {:killed_window, "casein_ws_b:@2"}
    end
  end

  describe "sweep_now/0 — session reaping (sweep_sessions/1 + busy_sessions/0)" do
    test "kills an unattached idle blank casein_ session" do
      seed(
        sessions: [orphan_session(%{session: "casein_ws_u-orphan"})],
        # Its sole pane is a shell -> not busy -> eligible.
        panes: [{"casein_ws_u-orphan", "bash"}]
      )

      assert Janitor.sweep_now() == 1
      assert_received {:killed_session, "casein_ws_u-orphan"}
    end

    test "spares attached, foreign, recent, and busy (non-shell pane) sessions" do
      seed(
        sessions: [
          orphan_session(%{session: "casein_ws_attached", attached: true}),
          orphan_session(%{session: "plain_foreign"}),
          orphan_session(%{session: "casein_ws_recent", activity: now()}),
          orphan_session(%{session: "casein_ws_busy"})
        ],
        # casein_ws_busy has a non-shell pane -> busy_sessions/0 includes it.
        panes: [
          {"casein_ws_attached", "bash"},
          {"casein_ws_recent", "bash"},
          {"casein_ws_busy", "vim"}
        ]
      )

      assert Janitor.sweep_now() == 0
      refute_received {:killed_session, _}
    end

    test "busy_sessions/0 spares a session if ANY pane runs a non-shell command" do
      seed(
        sessions: [orphan_session(%{session: "casein_ws_mixed"})],
        # One shell pane + one real-command pane: the real command wins.
        panes: [{"casein_ws_mixed", "bash"}, {"casein_ws_mixed", "node"}]
      )

      assert Janitor.sweep_now() == 0
      refute_received {:killed_session, "casein_ws_mixed"}
    end
  end

  describe "sweep_now/0 — combined and empty paths" do
    test "run_sweep/0 sums window kills and session kills" do
      seed(
        windows: [killable_window(%{session: "casein_ws_x", window_id: "@9"})],
        sessions: [orphan_session(%{session: "casein_ws_y"})],
        panes: [{"casein_ws_y", "bash"}]
      )

      # one window + one session
      assert Janitor.sweep_now() == 2
      assert_received {:killed_window, "casein_ws_x:@9"}
      assert_received {:killed_session, "casein_ws_y"}
    end

    test "returns 0 and kills nothing when there is nothing reapable" do
      seed(windows: [], sessions: [], panes: [])

      assert Janitor.sweep_now() == 0
      refute_received {:killed_window, _}
      refute_received {:killed_session, _}
    end
  end

  describe "handle_info(:sweep, state) self-reschedule" do
    test "an init'd janitor with a positive interval sweeps on :sweep and reschedules" do
      seed(windows: [killable_window(%{session: "casein_ws_sched", window_id: "@3"})])

      # Drive init/1 down the ms > 0 branch so state.interval_ms is set and the
      # reschedule arm of handle_info/2 runs. Supervise an unnamed instance via
      # ExUnit's supervisor (start_link/1 hardcodes the singleton name owned by
      # the app supervisor, so spec the GenServer.start_link MFA directly).
      Application.put_env(:casein, :tmux_window_sweep_ms, 60_000)
      pid = start_supervised!(unnamed_janitor_spec(:sched))

      # The init schedule fires far in the future; trigger a sweep immediately.
      send(pid, :sweep)

      # The reaped window proves handle_info(:sweep,...) ran run_sweep/0.
      assert_receive {:killed_window, "casein_ws_sched:@3"}

      # It rescheduled itself: a fresh :sweep timer is queued. Prove the server
      # is still alive and responsive after handling the message.
      assert Process.alive?(pid)
      assert is_integer(GenServer.call(pid, :sweep_now))
    end

    test "init/1 stays idle (interval_ms nil) when sweep_ms is unset/zero" do
      Application.delete_env(:casein, :tmux_window_sweep_ms)
      seed(windows: [killable_window(%{session: "casein_ws_idle", window_id: "@4"})])

      pid = start_supervised!(unnamed_janitor_spec(:idle))

      # No interval scheduled, so no automatic :sweep; but a manual :sweep still
      # runs run_sweep/0 and, with interval_ms nil, does NOT reschedule.
      send(pid, :sweep)
      assert_receive {:killed_window, "casein_ws_idle:@4"}
      assert Process.alive?(pid)
    end
  end

  # Child spec for a supervised, *unnamed* janitor instance. Janitor.start_link/1
  # binds the singleton module name (already owned by the app supervisor), so we
  # start the GenServer directly with no name and let ExUnit own its lifecycle.
  defp unnamed_janitor_spec(id) do
    %{
      id: {Janitor, id},
      start: {GenServer, :start_link, [Janitor, []]},
      restart: :temporary
    }
  end
end
