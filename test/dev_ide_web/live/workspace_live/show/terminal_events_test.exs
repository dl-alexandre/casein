defmodule DevIdeWeb.WorkspaceLive.Show.TerminalEventsTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspace
  alias DevIdeWeb.WorkspaceLive.Show.TerminalEvents

  test "terminal kill refuses tmux sessions outside the workspace prefix" do
    previous_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    previous_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())
    flush_mailbox()

    on_exit(fn ->
      restore_env(:dev_ide, :tmux_adapter, previous_adapter)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_test_pid, previous_pid)
    end)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        tmux_mutations_enabled?: true,
        workspace: %Workspace{id: "ws-1", name: "alpha"}
      }
    }

    other_session = DevIDE.Terminals.Tmux.session_name("beta", "u-dev")

    assert {:noreply, socket} =
             TerminalEvents.handle_event(
               "terminal:kill_session",
               %{"session-id" => "u-dev", "tmux-session" => other_session},
               socket
             )

    assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "outside this workspace"
    refute_received {:fake_tmux_kill_session, ^other_session}
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
