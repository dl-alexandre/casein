defmodule ExecCtl.Port do
  @moduledoc """
  erlexec plumbing for spawning an OS process and streaming output to a subscriber:

      {:cmd_data, ref, :stdout | :stderr, binary}
      {:cmd_exit, ref, exit_code :: integer() | {:error, term()}}

  `:cmd_exit` carries the OS exit code on normal termination, or
  `{:error, reason}` when the process went down abnormally or outlived the
  24-hour watchdog. Exactly one `:cmd_exit` is always delivered.
  """

  import Bitwise

  @spawn_timeout 30_000

  @spec run([String.t(), ...], keyword(), pid()) ::
          {:ok, reference(), map()} | {:error, term()}
  def run([bin | _] = argv, extra_opts, subscriber)
      when is_binary(bin) and is_list(extra_opts) and is_pid(subscriber) do
    ref = make_ref()
    cargv = Enum.map(argv, &to_charlist/1)
    owner = self()

    proxy =
      spawn_link(fn ->
        opts =
          [
            :monitor,
            {:stdout, fn _, _, data -> send(subscriber, {:cmd_data, ref, :stdout, data}) end},
            {:stderr, fn _, _, data -> send(subscriber, {:cmd_data, ref, :stderr, data}) end}
          ] ++ extra_opts

        case :exec.run(cargv, opts) do
          {:ok, exec_pid, ospid} ->
            send(owner, {:command_started, ref, {:ok, exec_pid, ospid}})
            wait_loop(subscriber, ref, ospid)

          {:error, reason} ->
            send(owner, {:command_started, ref, {:error, reason}})
        end
      end)

    receive do
      {:command_started, ^ref, {:ok, exec_pid, ospid}} ->
        {:ok, ref, %{exec_pid: exec_pid, ospid: ospid, proxy_pid: proxy}}

      {:command_started, ^ref, {:error, reason}} ->
        {:error, reason}
    after
      @spawn_timeout -> {:error, :spawn_timeout}
    end
  end

  @spec kill(map() | term()) :: :ok
  def kill(%{ospid: ospid}) do
    _ = :exec.kill(ospid, 15)
    :ok
  end

  def kill(_), do: :ok

  defp wait_loop(subscriber, ref, ospid) do
    receive do
      {:DOWN, _, :process, _, {:exit_status, status}} ->
        send(subscriber, {:cmd_exit, ref, exit_code_of(status)})

      {:DOWN, _, :process, _, :normal} ->
        send(subscriber, {:cmd_exit, ref, 0})

      {:DOWN, _, :process, _, reason} ->
        send(subscriber, {:cmd_exit, ref, {:error, reason}})
    after
      :timer.hours(24) ->
        _ = :exec.kill(ospid, 15)
        send(subscriber, {:cmd_exit, ref, {:error, :watchdog_timeout}})
    end
  end

  defp exit_code_of(status) when is_integer(status) do
    if band(status, 0xFF) == 0 do
      bsr(status, 8)
    else
      128 + band(status, 0x7F)
    end
  end

  defp exit_code_of(_), do: 1
end
