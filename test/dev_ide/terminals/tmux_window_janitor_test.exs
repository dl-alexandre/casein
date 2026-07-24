defmodule Casein.Terminals.TmuxWindowJanitorTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.TmuxWindowJanitor, as: Janitor
  alias TmuxCtl.Test.FakeState

  @now 1_000_000
  @idle 600

  setup do
    previous = %{
      runner: Application.get_env(:tmux_ctl, :runner),
      sweep_ms: Application.get_env(:dev_ide, :tmux_window_sweep_ms),
      window_idle: Application.get_env(:dev_ide, :tmux_window_idle_seconds),
      session_idle: Application.get_env(:dev_ide, :tmux_session_idle_seconds),
      list_windows_all: FakeState.get(:fake_tmux_list_windows_all),
      list_sessions: FakeState.get(:fake_tmux_list_sessions),
      list_panes_all: FakeState.get(:fake_tmux_list_panes_all),
      runner_pid: FakeState.get(:fake_tmux_runner_pid)
    }

    Application.put_env(:tmux_ctl, :runner, TmuxCtl.Test.FakeRunner)
    Application.put_env(:dev_ide, :tmux_window_idle_seconds, @idle)
    Application.put_env(:dev_ide, :tmux_session_idle_seconds, @idle)
    FakeState.put(:fake_tmux_runner_pid, self())

    on_exit(fn ->
      restore_env(:tmux_ctl, :runner, previous.runner)
      restore_env(:dev_ide, :tmux_window_sweep_ms, previous.sweep_ms)
      restore_env(:dev_ide, :tmux_window_idle_seconds, previous.window_idle)
      restore_env(:dev_ide, :tmux_session_idle_seconds, previous.session_idle)
      FakeState.restore(:fake_tmux_list_windows_all, previous.list_windows_all)
      FakeState.restore(:fake_tmux_list_sessions, previous.list_sessions)
      FakeState.restore(:fake_tmux_list_panes_all, previous.list_panes_all)
      FakeState.restore(:fake_tmux_runner_pid, previous.runner_pid)
    end)

    :ok
  end

  # A window that satisfies every kill condition; each test below flips exactly
  # one field to assert that condition is load-bearing.
  defp blank_window(overrides \\ %{}) do
    Map.merge(
      %{
        session: "devide_ws_u-abc-tab1",
        window_id: "@7",
        active: false,
        panes: 1,
        automatic_rename: true,
        current_command: "bash",
        activity: @now - @idle - 1
      },
      overrides
    )
  end

  test "reaps a blank, auto-named, idle, non-active shell window" do
    assert Janitor.killable?(blank_window(), @now, @idle)
  end

  test "spares foreign (non-devide_) sessions" do
    refute Janitor.killable?(blank_window(%{session: "other_session"}), @now, @idle)
  end

  test "spares a user-named window (automatic_rename off)" do
    refute Janitor.killable?(blank_window(%{automatic_rename: false}), @now, @idle)
  end

  test "spares the active window" do
    refute Janitor.killable?(blank_window(%{active: true}), @now, @idle)
  end

  test "spares a window running a real command" do
    for cmd <- ~w(vim nvim node iex ssh lazygit make) do
      refute Janitor.killable?(blank_window(%{current_command: cmd}), @now, @idle),
             "expected #{cmd} window to be spared"
    end
  end

  test "spares a multi-pane window" do
    refute Janitor.killable?(blank_window(%{panes: 2}), @now, @idle)
  end

  test "spares a window that is still within the idle window" do
    refute Janitor.killable?(blank_window(%{activity: @now - @idle + 5}), @now, @idle)
    # exactly at the threshold is eligible
    assert Janitor.killable?(blank_window(%{activity: @now - @idle}), @now, @idle)
  end

  test "accepts every recognized login-shell argv0 form" do
    # The full @shells set from the module — each must be treated as a blank shell.
    for sh <- ~w(bash zsh sh fish dash ash -bash -zsh -sh -fish) do
      assert Janitor.killable?(blank_window(%{current_command: sh}), @now, @idle),
             "expected #{sh} to be treated as a blank shell"
    end
  end

  test "exactly at the idle threshold is eligible, one second short is not" do
    assert Janitor.killable?(blank_window(%{activity: @now - @idle}), @now, @idle)
    refute Janitor.killable?(blank_window(%{activity: @now - @idle + 1}), @now, @idle)
    # Well past the threshold stays eligible.
    assert Janitor.killable?(blank_window(%{activity: @now - @idle - 1000}), @now, @idle)
  end

  test "an idle threshold of zero reaps any non-active blank shell window" do
    assert Janitor.killable?(blank_window(%{activity: @now}), @now, 0)
  end

  describe "session_killable?/4" do
    defp orphan_session(overrides \\ %{}) do
      Map.merge(
        %{session: "devide_ws_u-abc-tab1", attached: false, activity: @now - @idle - 1},
        overrides
      )
    end

    @empty MapSet.new()

    test "reaps an unattached, idle, blank devide_ session" do
      assert Janitor.session_killable?(orphan_session(), @now, @idle, @empty)
    end

    test "spares foreign sessions" do
      refute Janitor.session_killable?(orphan_session(%{session: "work"}), @now, @idle, @empty)
    end

    test "spares an attached (live viewer) session" do
      refute Janitor.session_killable?(orphan_session(%{attached: true}), @now, @idle, @empty)
    end

    test "spares a session with a non-shell pane (busy)" do
      busy = MapSet.new(["devide_ws_u-abc-tab1"])
      refute Janitor.session_killable?(orphan_session(), @now, @idle, busy)
    end

    test "spares a session still within the idle window" do
      refute Janitor.session_killable?(
               orphan_session(%{activity: @now - @idle + 5}),
               @now,
               @idle,
               @empty
             )
    end

    test "exactly at the idle threshold is eligible, one second short is not" do
      assert Janitor.session_killable?(
               orphan_session(%{activity: @now - @idle}),
               @now,
               @idle,
               @empty
             )

      refute Janitor.session_killable?(
               orphan_session(%{activity: @now - @idle + 1}),
               @now,
               @idle,
               @empty
             )
    end

    test "a non-empty busy set that excludes this session does not spare it" do
      other = MapSet.new(["devide_ws_other-tab"])
      assert Janitor.session_killable?(orphan_session(), @now, @idle, other)
    end

    test "spares a foreign session even when unattached, idle and not busy" do
      refute Janitor.session_killable?(
               orphan_session(%{session: "phoenix"}),
               @now,
               @idle,
               @empty
             )
    end
  end

  describe "sweep_now/0" do
    test "returns zero when nothing is eligible" do
      FakeState.put(:fake_tmux_list_windows_all, "")
      FakeState.put(:fake_tmux_list_sessions, "")
      FakeState.put(:fake_tmux_list_panes_all, "")

      assert Janitor.sweep_now() == 0
    end

    test "dry_run_now reports eligible windows and sessions without mutating tmux" do
      now = System.system_time(:second)
      idle_activity = now - @idle - 5

      FakeState.put(
        :fake_tmux_list_windows_all,
        [
          "devide_ws_u-abc-tab1|@7|0|1|1|#{idle_activity}|bash",
          "devide_ws_u-abc-tab1|@1|1|1|1|#{idle_activity}|bash",
          "other_session|@2|0|1|1|#{idle_activity}|bash"
        ]
        |> Enum.join("\n")
      )

      FakeState.put(
        :fake_tmux_list_sessions,
        [
          "devide_ws_u-orphan|0|#{idle_activity}|",
          "devide_ws_u-busy|0|#{idle_activity}|"
        ]
        |> Enum.join("\n")
      )

      FakeState.put(:fake_tmux_list_panes_all, "devide_ws_u-busy|vim\n")

      assert %{
               total: 2,
               windows: [
                 %{
                   session: "devide_ws_u-abc-tab1",
                   window_id: "@7",
                   reason: :blank_idle_window
                 }
               ],
               sessions: [
                 %{session: "devide_ws_u-orphan", reason: :blank_orphan_session}
               ]
             } = Janitor.dry_run_now()

      refute_received {:tmux_runner, ["kill-window" | _]}
      refute_received {:tmux_runner, ["kill-session" | _]}
    end

    test "kills blank idle windows and orphaned sessions" do
      now = System.system_time(:second)
      idle_activity = now - @idle - 5

      FakeState.put(
        :fake_tmux_list_windows_all,
        [
          "devide_ws_u-abc-tab1|@7|0|1|1|#{idle_activity}|bash",
          "devide_ws_u-abc-tab1|@1|1|1|1|#{idle_activity}|bash",
          "other_session|@2|0|1|1|#{idle_activity}|bash"
        ]
        |> Enum.join("\n")
      )

      FakeState.put(
        :fake_tmux_list_sessions,
        [
          "devide_ws_u-orphan|0|#{idle_activity}|",
          "devide_ws_u-busy|0|#{idle_activity}|"
        ]
        |> Enum.join("\n")
      )

      FakeState.put(
        :fake_tmux_list_panes_all,
        "devide_ws_u-busy|vim\n"
      )

      assert Janitor.sweep_now() == 2

      assert_receive {:tmux_runner, ["kill-window", "-t", "devide_ws_u-abc-tab1:@7"]}
      assert_receive {:tmux_runner, ["kill-session", "-t", "devide_ws_u-orphan"]}
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
