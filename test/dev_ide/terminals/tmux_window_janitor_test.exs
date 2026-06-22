defmodule DevIDE.Terminals.TmuxWindowJanitorTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.TmuxWindowJanitor, as: Janitor
  alias TmuxCtl.Test.FakeState

  @now 1_000_000
  @idle 600

  setup do
    prev_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_windows = FakeState.get(:fake_tmux_windows)
    prev_panes = FakeState.get(:fake_tmux_panes)
    prev_meta = FakeState.get(:fake_tmux_session_meta)
    prev_test_pid = FakeState.get(:fake_tmux_test_pid)

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    FakeState.put(:fake_tmux_test_pid, self())

    on_exit(fn ->
      restore_env(:tmux_adapter, prev_adapter)
      restore_fake(:fake_tmux_windows, prev_windows)
      restore_fake(:fake_tmux_panes, prev_panes)
      restore_fake(:fake_tmux_session_meta, prev_meta)
      restore_fake(:fake_tmux_test_pid, prev_test_pid)
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

  test "accepts common login-shell argv0 forms" do
    for sh <- ~w(bash zsh sh fish -bash -zsh) do
      assert Janitor.killable?(blank_window(%{current_command: sh}), @now, @idle),
             "expected #{sh} to be treated as a blank shell"
    end
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
  end

  describe "dry-run and sweep" do
    test "dry_run_now reports eligible windows and sessions without mutating tmux" do
      seed_fake_tmux!()

      result = Janitor.dry_run_now()

      assert result.total == 2

      assert [%{session: "devide_ws_u-dev", window_id: "@2", reason: :blank_idle_window}] =
               result.windows

      assert [%{session: "devide_orphan_u-dev", reason: :blank_orphan_session}] =
               result.sessions

      assert Map.has_key?(FakeState.get(:fake_tmux_windows), "devide_orphan_u-dev")
      refute_received {:fake_tmux_kill_window, _, _}
      refute_received {:fake_tmux_kill_session, _}
    end

    test "sweep_now kills only dry-run eligible windows and sessions" do
      seed_fake_tmux!()

      assert Janitor.sweep_now() == 2

      assert_received {:fake_tmux_kill_window, "devide_ws_u-dev", "@2"}
      assert_received {:fake_tmux_kill_session, "devide_orphan_u-dev"}

      windows = FakeState.get(:fake_tmux_windows)
      refute Map.has_key?(windows, "devide_orphan_u-dev")
      assert Enum.map(windows["devide_ws_u-dev"], & &1.id) == ["@1"]
      assert Map.has_key?(windows, "devide_busy_u-dev")
      assert Map.has_key?(windows, "foreign")
    end
  end

  defp seed_fake_tmux! do
    now = System.system_time(:second)
    old = now - 1_000

    FakeState.put(:fake_tmux_windows, %{
      "devide_ws_u-dev" => [
        %{
          id: "@1",
          window_id: "@1",
          active: true,
          panes: 1,
          automatic_rename: true,
          current_command: "bash",
          activity: old
        },
        %{
          id: "@2",
          window_id: "@2",
          active: false,
          panes: 1,
          automatic_rename: true,
          current_command: "bash",
          activity: old
        }
      ],
      "devide_orphan_u-dev" => [
        %{
          id: "@1",
          window_id: "@1",
          active: true,
          panes: 1,
          automatic_rename: true,
          current_command: "bash",
          activity: old
        }
      ],
      "devide_busy_u-dev" => [
        %{
          id: "@1",
          window_id: "@1",
          active: true,
          panes: 1,
          automatic_rename: true,
          current_command: "node",
          activity: old
        }
      ],
      "foreign" => [
        %{
          id: "@1",
          window_id: "@1",
          active: false,
          panes: 1,
          automatic_rename: true,
          current_command: "bash",
          activity: old
        }
      ]
    })

    FakeState.put(:fake_tmux_panes, %{
      "devide_ws_u-dev" => [%{id: "%1", window_id: "@1", current_command: "bash"}],
      "devide_orphan_u-dev" => [%{id: "%2", window_id: "@1", current_command: "bash"}],
      "devide_busy_u-dev" => [%{id: "%3", window_id: "@1", current_command: "node"}],
      "foreign" => [%{id: "%4", window_id: "@1", current_command: "bash"}]
    })

    FakeState.put(:fake_tmux_session_meta, %{
      "devide_ws_u-dev" => %{attached: true, activity: old},
      "devide_orphan_u-dev" => %{attached: false, activity: old},
      "devide_busy_u-dev" => %{attached: false, activity: old},
      "foreign" => %{attached: false, activity: old}
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)

  defp restore_fake(key, nil), do: FakeState.delete(key)
  defp restore_fake(key, value), do: FakeState.put(key, value)
end
