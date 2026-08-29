defmodule Casein.Terminals.TmuxWindowJanitorTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.TmuxWindowJanitor, as: Janitor
  alias TmuxCtl.Test.FakeState

  @now 1_000_000
  @idle 600

  setup do
    previous = %{
      runner: Application.get_env(:tmux_ctl, :runner),
      sweep_ms: Application.get_env(:casein, :tmux_window_sweep_ms),
      window_idle: Application.get_env(:casein, :tmux_window_idle_seconds),
      session_idle: Application.get_env(:casein, :tmux_session_idle_seconds),
      agent_idle: Application.get_env(:casein, :tmux_agent_idle_seconds),
      clean_fn: Application.get_env(:casein, :tmux_agent_worktree_clean_fn),
      list_windows_all: FakeState.get(:fake_tmux_list_windows_all),
      list_sessions: FakeState.get(:fake_tmux_list_sessions),
      list_panes_all: FakeState.get(:fake_tmux_list_panes_all),
      runner_pid: FakeState.get(:fake_tmux_runner_pid)
    }

    Application.put_env(:tmux_ctl, :runner, TmuxCtl.Test.FakeRunner)
    Application.put_env(:casein, :tmux_window_idle_seconds, @idle)
    Application.put_env(:casein, :tmux_session_idle_seconds, @idle)
    FakeState.put(:fake_tmux_runner_pid, self())

    on_exit(fn ->
      restore_env(:tmux_ctl, :runner, previous.runner)
      restore_env(:casein, :tmux_window_sweep_ms, previous.sweep_ms)
      restore_env(:casein, :tmux_window_idle_seconds, previous.window_idle)
      restore_env(:casein, :tmux_session_idle_seconds, previous.session_idle)
      restore_env(:casein, :tmux_agent_idle_seconds, previous.agent_idle)
      restore_env(:casein, :tmux_agent_worktree_clean_fn, previous.clean_fn)
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
        session: "casein_ws_u-abc-tab1",
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

  test "spares foreign (non-casein_) sessions" do
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
        %{session: "casein_ws_u-abc-tab1", attached: false, activity: @now - @idle - 1},
        overrides
      )
    end

    @empty MapSet.new()

    test "reaps an unattached, idle, blank casein_ session" do
      assert Janitor.session_killable?(orphan_session(), @now, @idle, @empty)
    end

    test "spares foreign sessions" do
      refute Janitor.session_killable?(orphan_session(%{session: "work"}), @now, @idle, @empty)
    end

    test "spares an attached (live viewer) session" do
      refute Janitor.session_killable?(orphan_session(%{attached: true}), @now, @idle, @empty)
    end

    test "spares a session with a non-shell pane (busy)" do
      busy = MapSet.new(["casein_ws_u-abc-tab1"])
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
      other = MapSet.new(["casein_ws_other-tab"])
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

  describe "agent_killable?/4" do
    @agent_idle 7200

    defp agent_window(overrides \\ %{}) do
      Map.merge(
        %{
          session: "casein_ws_u-abc-agent",
          window_id: "@1",
          active: true,
          panes: 1,
          automatic_rename: true,
          current_command: "opencode",
          current_path: "/tmp/casein-agent-worktrees/agent-opencode-x",
          activity: @now - @agent_idle - 1
        },
        overrides
      )
    end

    @nobody MapSet.new()

    test "reaps an unattached, idle, single-pane agent window (even the active one)" do
      assert Janitor.agent_killable?(agent_window(), @now, @agent_idle, @nobody)
    end

    test "spares a session with an attached client" do
      attached = MapSet.new(["casein_ws_u-abc-agent"])
      refute Janitor.agent_killable?(agent_window(), @now, @agent_idle, attached)
    end

    test "spares foreign sessions" do
      refute Janitor.agent_killable?(agent_window(%{session: "work"}), @now, @agent_idle, @nobody)
    end

    test "spares a window whose foreground is not an agent" do
      for cmd <- ~w(bash vim node iex mix) do
        refute Janitor.agent_killable?(
                 agent_window(%{current_command: cmd}),
                 @now,
                 @agent_idle,
                 @nobody
               ),
               "expected #{cmd} window to be spared"
      end
    end

    test "recognises every agent binary, including the comm form of claude.exe" do
      for cmd <- ~w(claude claude_exe claude.exe grok codex opencode) do
        assert Janitor.agent_process?(cmd), "expected #{cmd} to be an agent process"
      end

      refute Janitor.agent_process?(nil)
      refute Janitor.agent_process?("claudette")
    end

    test "spares a multi-pane window" do
      refute Janitor.agent_killable?(agent_window(%{panes: 2}), @now, @agent_idle, @nobody)
    end

    test "exactly at the idle threshold is eligible, one second short is not" do
      assert Janitor.agent_killable?(
               agent_window(%{activity: @now - @agent_idle}),
               @now,
               @agent_idle,
               @nobody
             )

      refute Janitor.agent_killable?(
               agent_window(%{activity: @now - @agent_idle + 1}),
               @now,
               @agent_idle,
               @nobody
             )
    end
  end

  describe "git_worktree_clean?/1" do
    test "a directory that is not a git repository is not clean" do
      dir =
        Path.join(System.tmp_dir!(), "janitor-not-a-repo-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      refute Janitor.git_worktree_clean?(dir)
    end

    test "nil, empty and missing paths are not clean" do
      refute Janitor.git_worktree_clean?(nil)
      refute Janitor.git_worktree_clean?("")
      refute Janitor.git_worktree_clean?("/definitely/not/here/#{System.unique_integer()}")
    end

    test "a fresh repo is clean until a file appears" do
      dir = Path.join(System.tmp_dir!(), "janitor-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {_, 0} = System.cmd("git", ["-C", dir, "init", "-q"], stderr_to_stdout: true)

      assert Janitor.git_worktree_clean?(dir)

      File.write!(Path.join(dir, "scratch.txt"), "unsaved")
      refute Janitor.git_worktree_clean?(dir)
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
          "casein_ws_u-abc-tab1|@7|0|1|1|#{idle_activity}|bash",
          "casein_ws_u-abc-tab1|@1|1|1|1|#{idle_activity}|bash",
          "other_session|@2|0|1|1|#{idle_activity}|bash"
        ]
        |> Enum.join("\n")
      )

      FakeState.put(
        :fake_tmux_list_sessions,
        [
          "casein_ws_u-orphan|0|#{idle_activity}|",
          "casein_ws_u-busy|0|#{idle_activity}|"
        ]
        |> Enum.join("\n")
      )

      FakeState.put(:fake_tmux_list_panes_all, "casein_ws_u-busy|vim\n")

      assert %{
               total: 2,
               windows: [
                 %{
                   session: "casein_ws_u-abc-tab1",
                   window_id: "@7",
                   reason: :blank_idle_window
                 }
               ],
               sessions: [
                 %{session: "casein_ws_u-orphan", reason: :blank_orphan_session}
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
          "casein_ws_u-abc-tab1|@7|0|1|1|#{idle_activity}|bash",
          "casein_ws_u-abc-tab1|@1|1|1|1|#{idle_activity}|bash",
          "other_session|@2|0|1|1|#{idle_activity}|bash"
        ]
        |> Enum.join("\n")
      )

      FakeState.put(
        :fake_tmux_list_sessions,
        [
          "casein_ws_u-orphan|0|#{idle_activity}|",
          "casein_ws_u-busy|0|#{idle_activity}|"
        ]
        |> Enum.join("\n")
      )

      FakeState.put(
        :fake_tmux_list_panes_all,
        "casein_ws_u-busy|vim\n"
      )

      assert Janitor.sweep_now() == 2

      assert_receive {:tmux_runner, ["kill-window", "-t", "casein_ws_u-abc-tab1:@7"]}
      assert_receive {:tmux_runner, ["kill-session", "-t", "casein_ws_u-orphan"]}
    end

    test "agent reaping is off unless :tmux_agent_idle_seconds is configured" do
      now = System.system_time(:second)
      stale = now - 10 * @idle

      Application.delete_env(:casein, :tmux_agent_idle_seconds)
      Application.put_env(:casein, :tmux_agent_worktree_clean_fn, fn _ -> true end)

      FakeState.put(
        :fake_tmux_list_windows_all,
        "casein_ws_u-agent|@1|1|1|1|#{stale}|opencode|/tmp/wt"
      )

      FakeState.put(:fake_tmux_list_sessions, "casein_ws_u-agent|0|#{stale}|")
      FakeState.put(:fake_tmux_list_panes_all, "casein_ws_u-agent|opencode\n")

      assert %{total: 0, agents: []} = Janitor.dry_run_now()
      assert Janitor.sweep_now() == 0
      refute_received {:tmux_runner, ["kill-session" | _]}
      refute_received {:tmux_runner, ["kill-window" | _]}
    end

    test "kills the whole session when the idle agent window is its only window" do
      now = System.system_time(:second)
      stale = now - 10 * @idle

      Application.put_env(:casein, :tmux_agent_idle_seconds, @idle)
      Application.put_env(:casein, :tmux_agent_worktree_clean_fn, fn "/tmp/wt" -> true end)

      FakeState.put(
        :fake_tmux_list_windows_all,
        "casein_ws_u-agent|@1|1|1|1|#{stale}|opencode|/tmp/wt"
      )

      FakeState.put(:fake_tmux_list_sessions, "casein_ws_u-agent|0|#{stale}|")
      FakeState.put(:fake_tmux_list_panes_all, "casein_ws_u-agent|opencode\n")

      assert %{
               total: 1,
               windows: [],
               sessions: [],
               agents: [
                 %{
                   session: "casein_ws_u-agent",
                   window_id: "@1",
                   reason: :idle_agent_window,
                   current_path: "/tmp/wt",
                   last_window: true
                 }
               ]
             } = Janitor.dry_run_now()

      assert Janitor.sweep_now() == 1
      assert_receive {:tmux_runner, ["kill-session", "-t", "casein_ws_u-agent"]}
      refute_received {:tmux_runner, ["kill-window" | _]}
    end

    test "kills just the window when the session has others" do
      now = System.system_time(:second)
      stale = now - 10 * @idle

      Application.put_env(:casein, :tmux_agent_idle_seconds, @idle)
      Application.put_env(:casein, :tmux_agent_worktree_clean_fn, fn _ -> true end)

      FakeState.put(
        :fake_tmux_list_windows_all,
        [
          "casein_ws_u-agent|@1|0|1|1|#{stale}|claude_exe|/tmp/wt",
          "casein_ws_u-agent|@2|1|1|1|#{now}|bash|/tmp/wt"
        ]
        |> Enum.join("\n")
      )

      FakeState.put(:fake_tmux_list_sessions, "casein_ws_u-agent|0|#{now}|")

      FakeState.put(
        :fake_tmux_list_panes_all,
        "casein_ws_u-agent|claude_exe\ncasein_ws_u-agent|bash\n"
      )

      assert %{total: 1, agents: [%{window_id: "@1", last_window: false}]} = Janitor.dry_run_now()
      assert Janitor.sweep_now() == 1
      assert_receive {:tmux_runner, ["kill-window", "-t", "casein_ws_u-agent:@1"]}
      refute_received {:tmux_runner, ["kill-session" | _]}
    end

    test "spares an idle agent whose worktree is dirty, and one with a live viewer" do
      now = System.system_time(:second)
      stale = now - 10 * @idle

      Application.put_env(:casein, :tmux_agent_idle_seconds, @idle)

      Application.put_env(:casein, :tmux_agent_worktree_clean_fn, fn
        "/tmp/dirty" -> false
        _ -> true
      end)

      FakeState.put(
        :fake_tmux_list_windows_all,
        [
          "casein_ws_u-dirty|@1|1|1|1|#{stale}|opencode|/tmp/dirty",
          "casein_ws_u-viewed|@1|1|1|1|#{stale}|opencode|/tmp/wt"
        ]
        |> Enum.join("\n")
      )

      FakeState.put(
        :fake_tmux_list_sessions,
        "casein_ws_u-dirty|0|#{stale}|\ncasein_ws_u-viewed|1|#{stale}|"
      )

      FakeState.put(
        :fake_tmux_list_panes_all,
        "casein_ws_u-dirty|opencode\ncasein_ws_u-viewed|opencode\n"
      )

      assert %{total: 0, agents: []} = Janitor.dry_run_now()
      assert Janitor.sweep_now() == 0
      refute_received {:tmux_runner, ["kill-session" | _]}
      refute_received {:tmux_runner, ["kill-window" | _]}
    end

    test "an agent window with no known path is spared (path is required for the clean check)" do
      now = System.system_time(:second)
      stale = now - 10 * @idle

      Application.put_env(:casein, :tmux_agent_idle_seconds, @idle)
      # 7-field line: older format without pane_current_path → current_path nil.
      FakeState.put(:fake_tmux_list_windows_all, "casein_ws_u-agent|@1|1|1|1|#{stale}|opencode")
      FakeState.put(:fake_tmux_list_sessions, "casein_ws_u-agent|0|#{stale}|")
      FakeState.put(:fake_tmux_list_panes_all, "casein_ws_u-agent|opencode\n")

      assert %{total: 0} = Janitor.dry_run_now()
      assert Janitor.sweep_now() == 0
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
