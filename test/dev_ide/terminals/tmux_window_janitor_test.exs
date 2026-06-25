defmodule DevIDE.Terminals.TmuxWindowJanitorTest do
  use ExUnit.Case, async: true

  alias DevIDE.Terminals.TmuxWindowJanitor, as: Janitor

  @now 1_000_000
  @idle 600

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
end
