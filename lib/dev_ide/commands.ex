defmodule DevIDE.Commands do
  @moduledoc """
  Allowlist enumeration for the command palette, plus local subprocess spawning
  for `DevIDE.Agents.Run` (review-mode agent runs).

  Allowlist enumeration is allowlisted, argv-style, no shell interpolation. The
  delegated-execution adapters were removed; the only remaining executor is the
  local erlexec spawn below, used solely to run fixed `DevIDE.Agents.ReviewCommand`
  argv on the local host. Output streams to the subscriber pid:

      {:cmd_data, ref, :stdout | :stderr, binary}
      {:cmd_exit, ref, exit_code :: integer()}
  """

  alias DevIDE.Commands.Allowlist

  @type id :: String.t()
  @type argv :: [String.t()]

  @doc "Map of allowlist id → argv. Stable for tests."
  def allowlist, do: Allowlist.all()
  def allowed?(id), do: Allowlist.allowed?(id)
  def argv_for(id), do: Allowlist.argv_for(id)

  @doc """
  Spawns a local subprocess via erlexec (no PTY — distinct stdout/stderr
  channels), streaming line-buffered output to the subscriber pid.
  """
  @spec spawn(String.t(), argv(), pid()) :: {:ok, reference(), term()} | {:error, term()}
  def spawn(root, [bin | args], subscriber)
      when is_binary(root) and is_binary(bin) and is_list(args) and is_pid(subscriber) do
    spawn(root, [bin | args], subscriber, [])
  end

  def spawn(_, _, _), do: {:error, :bad_args}

  @doc "Spawn a command with bounded erlexec options such as environment removals."
  @spec spawn(String.t(), argv(), pid(), keyword()) ::
          {:ok, reference(), term()} | {:error, term()}
  def spawn(root, [bin | args], subscriber, opts)
      when is_binary(root) and is_binary(bin) and is_list(args) and is_pid(subscriber) do
    if File.dir?(root) do
      with {:ok, executable} <- resolve_executable(bin) do
        ref = make_ref()
        argv = [to_charlist(executable) | Enum.map(args, &to_charlist/1)]

        owner = self()

        proxy_pid =
          spawn_link(fn -> run_and_monitor(owner, subscriber, ref, root, argv, opts) end)

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
    else
      {:error, :no_root}
    end
  end

  def spawn(_, _, _, _), do: {:error, :bad_args}

  @spec kill(term()) :: :ok
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

  defp run_and_monitor(owner, subscriber, ref, root, argv, spawn_opts) do
    opts =
      [
        :monitor,
        {:cd, to_charlist(root)},
        {:stdout, &forward(subscriber, ref, :stdout, &1, &2, &3)},
        {:stderr, &forward(subscriber, ref, :stderr, &1, &2, &3)}
      ] ++ environment_opts(spawn_opts)

    case :exec.run(argv, opts) do
      {:ok, exec_pid, ospid} ->
        send(owner, {:command_started, ref, {:ok, exec_pid, ospid}})
        subscriber_ref = Process.monitor(subscriber)
        wait_exit(subscriber, subscriber_ref, ref, exec_pid, ospid)

      {:error, reason} ->
        send(owner, {:command_started, ref, {:error, reason}})
    end
  end

  defp environment_opts(opts) do
    case Keyword.get(opts, :env) do
      env when is_list(env) -> [{:env, env}]
      _other -> []
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
