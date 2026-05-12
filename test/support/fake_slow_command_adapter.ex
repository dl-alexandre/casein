defmodule DevIDE.Test.FakeSlowCommandAdapter do
  @moduledoc false
  @behaviour DevIDE.Commands

  @impl true
  def spawn(root, argv, subscriber) do
    ref = make_ref()
    test_pid = test_pid()

    pid =
      spawn(fn ->
        send(test_pid, {:fake_slow_command_spawned, root, argv, self(), ref})

        receive do
          {:finish, code} ->
            send(subscriber, {:cmd_data, ref, :stdout, "slow ok\n"})
            send(subscriber, {:cmd_exit, ref, code})
        end
      end)

    {:ok, ref, pid}
  end

  @impl true
  def kill(pid) when is_pid(pid) do
    send(pid, {:finish, :timeout})
    :ok
  end

  defp test_pid do
    Application.get_env(:dev_ide, :fake_command_test_pid, self())
  end
end
