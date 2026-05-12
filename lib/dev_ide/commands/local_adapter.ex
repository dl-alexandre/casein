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
      with {:ok, executable} <- resolve_executable(bin) do
        ref = make_ref()
        argv = [to_charlist(executable) | Enum.map(args, &to_charlist/1)]

        owner = self()
        proxy_pid = spawn_link(fn -> run_and_monitor(owner, subscriber, ref, root, argv) end)

        receive do
          {:command_started, ^ref, {:ok, exec_pid, ospid}} ->
            {:ok, ref, %{exec_pid: exec_pid, ospid: ospid, proxy_pid: proxy_pid}}

          {:command_started, ^ref, {:error, reason}} ->
            {:error, reason}
        after
          30_000 ->
            {:error, :spawn_timeout}
        end
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

  defp resolve_executable(bin) do
    cond do
      String.contains?(bin, "/") ->
        {:ok, bin}

      executable = System.find_executable(bin) ->
        {:ok, executable}

      true ->
        {:error, {:executable_not_found, bin}}
    end
  end

  defp run_and_monitor(owner, subscriber, ref, root, argv) do
    opts = [
      :monitor,
      {:cd, to_charlist(root)},
      {:stdout, &forward(subscriber, ref, :stdout, &1, &2, &3)},
      {:stderr, &forward(subscriber, ref, :stderr, &1, &2, &3)}
    ]

    case :exec.run(argv, opts) do
      {:ok, exec_pid, ospid} ->
        send(owner, {:command_started, ref, {:ok, exec_pid, ospid}})
        subscriber_ref = Process.monitor(subscriber)
        wait_exit(subscriber, subscriber_ref, ref, exec_pid, ospid)

      {:error, reason} ->
        send(owner, {:command_started, ref, {:error, reason}})
    end
  end

  defp wait_exit(subscriber, subscriber_ref, ref, exec_pid, ospid) do
    receive do
      {:DOWN, ^ospid, :process, ^exec_pid, reason} ->
        send(subscriber, {:cmd_exit, ref, exit_code(reason)})

      {:DOWN, ^subscriber_ref, :process, ^subscriber, _reason} ->
        _ = :exec.kill(ospid, 15)
        :ok

      _ ->
        wait_exit(subscriber, subscriber_ref, ref, exec_pid, ospid)
    after
      :timer.hours(2) -> send(subscriber, {:cmd_exit, ref, :timeout})
    end
  end

  defp exit_code({:exit_status, status}) when is_integer(status) do
    # erlexec packs signal/exit; lower 8 bits = exit, upper = signal
    if status >= 256, do: Bitwise.bsr(status, 8), else: status
  end

  defp exit_code(:normal), do: 0
  defp exit_code(other), do: {:abnormal, other}
end
