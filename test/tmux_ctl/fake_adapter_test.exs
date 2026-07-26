defmodule TmuxCtl.FakeAdapterTest do
  use Casein.TestCase, async: false

  alias TmuxCtl.Test.{FakeAdapter, FakeState}

  @session "casein_alpha_main"

  setup do
    previous_windows = FakeState.get(:fake_tmux_windows)
    previous_panes = FakeState.get(:fake_tmux_panes)
    previous_test_pid = FakeState.get(:fake_tmux_test_pid)

    FakeState.put(:fake_tmux_windows, %{})
    FakeState.put(:fake_tmux_panes, %{})
    FakeState.delete(:fake_tmux_test_pid)

    on_exit(fn ->
      FakeState.restore(:fake_tmux_windows, previous_windows)
      FakeState.restore(:fake_tmux_panes, previous_panes)
      FakeState.restore(:fake_tmux_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "killing the active window clears history when the last window becomes active" do
    FakeState.put(:fake_tmux_windows, %{
      @session => [
        %{id: "@0", active: true, last: false},
        %{id: "@1", active: false, last: true}
      ]
    })

    assert :ok = FakeAdapter.kill_window(@session, "@0")
    assert [%{id: "@1", active: true, last: false}] = FakeAdapter.list_session_windows(@session)
    assert {:error, :no_last_window} = FakeAdapter.last_window(@session)
  end

  test "consolidating sessions does not import source window history" do
    source = "casein_alpha_agent"

    FakeState.put(:fake_tmux_windows, %{
      @session => [
        %{id: "@0", index: 0, active: true, last: false},
        %{id: "@1", index: 1, active: false, last: true}
      ],
      source => [
        %{id: "@2", index: 0, active: true, last: false},
        %{id: "@3", index: 1, active: false, last: true}
      ]
    })

    assert {:ok, %{moved_windows: 2, source_sessions: 1}} =
             FakeAdapter.consolidate_sessions(@session, [source])

    windows = FakeAdapter.list_session_windows(@session)
    assert Enum.filter(windows, & &1.last) |> Enum.map(& &1.id) == ["@1"]
    assert Enum.filter(windows, &(&1.id in ["@2", "@3"])) |> Enum.all?(&(&1.last == false))
  end
end
