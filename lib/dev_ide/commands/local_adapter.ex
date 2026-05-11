defmodule DevIDE.Commands.LocalAdapter do
  @moduledoc """
  Local-host command runner. Uses erlexec (no PTY — distinct stdout/stderr
  channels) and streams line-buffered output to the subscriber pid:

      {:cmd_data, ref, :stdout | :stderr, binary}
      {:cmd_exit, ref, exit_code :: integer()}
  """

  @behaviour DevIDE.Commands

  @impl true
  def spawn(root, [bin | args], subscriber)
      when is_binary(root) and is_binary(bin) and is_list(args) and is_pid(subscriber) do
    if not File.dir?(root) do
      {:error, :no_root}
    else
      ref = make_ref()
      argv = [to_charlist(bin) | Enum.map(args, &to_charlist/1)]

      opts = [
        :monitor,
        {:cd, to_charlist(root)},
        {:stdout, &forward(subscriber, ref, :stdout, &1, &2, &3)},
        {:stderr, &forward(subscriber, ref, :stderr, &1, &2, &3)}
      ]

      case :exec.run(argv, opts) do
        {:ok, exec_pid, ospid} ->
          spawn_link(fn -> wait_exit(subscriber, ref, ospid) end)
          {:ok, ref, %{exec_pid: exec_pid, ospid: ospid}}

        err ->
          err
      end
    end
  end

  def spawn(_, _, _), do: {:error, :bad_args}

  @impl true
  def kill(%{ospid: ospid}) do
    _ = :exec.kill(ospid, 15)
    :ok
  end

  def kill(_), do: :ok

  defp forward(subscriber, ref, stream, _stream_id, _ospid, data) do
    send(subscriber, {:cmd_data, ref, stream, data})
  end

  defp wait_exit(subscriber, ref, ospid) do
    receive do
      {:DOWN, ^ospid, :process, _, reason} ->
        send(subscriber, {:cmd_exit, ref, exit_code(reason)})

      _ ->
        wait_exit(subscriber, ref, ospid)
    after
      :timer.hours(2) -> send(subscriber, {:cmd_exit, ref, :timeout})
    end
  end

  defp exit_code({:exit_status, status}) when is_integer(status) do
    # erlexec packs signal/exit; lower 8 bits = exit, upper = signal
    Bitwise.bsr(status, 8)
  end

  defp exit_code(:normal), do: 0
  defp exit_code(other), do: {:abnormal, other}
end
