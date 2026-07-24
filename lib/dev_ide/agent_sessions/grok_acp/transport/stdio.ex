defmodule Casein.AgentSessions.GrokACP.Transport.Stdio do
  @moduledoc """
  Bidirectional ACP transport through Grok's supported stdio bridge.

  The bridge attaches through `grok agent --leader stdio`, leaving Grok
  responsible for its private IPC registration, framing, keepalives, and
  reconnect logic. Standalone callers may ask the transport to start a leader;
  production hook attachments use `leader_mode: :attach` because the managed
  launcher already owns and supervises the trusted leader process group.
  stdout remains protocol-only; stderr is delivered separately to the owner.
  """

  @behaviour Casein.AgentSessions.GrokACP.Transport

  @default_leader_timeout_ms 10_000
  @socket_poll_ms 25

  @impl true
  def start(owner, opts) when is_pid(owner) and is_list(opts) do
    ref = make_ref()
    caller = self()

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)
        start_processes(caller, owner, ref, opts)
      end)

    timeout_ms = Keyword.get(opts, :leader_timeout_ms, @default_leader_timeout_ms) + 5_000

    receive do
      {:grok_acp_transport_started, ^ref, :ok} -> {:ok, %{pid: pid, ref: ref}}
      {:grok_acp_transport_started, ^ref, {:error, reason}} -> {:error, reason}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        {:error, :transport_start_timeout}
    end
  end

  @impl true
  def write(%{pid: pid}, data) when is_pid(pid) do
    if Process.alive?(pid) do
      send(pid, {:write, IO.iodata_to_binary(data)})
      :ok
    else
      {:error, :transport_closed}
    end
  end

  @impl true
  def stop(%{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
    :ok
  end

  defp start_processes(caller, owner, ref, opts) do
    with {:ok, executable} <- resolve_executable(opts),
         {:ok, cwd} <- resolve_cwd(opts),
         {:ok, socket_path} <- resolve_socket_path(opts),
         :ok <- ensure_socket_parent(socket_path),
         {:ok, leader} <- prepare_leader(executable, cwd, socket_path, opts),
         :ok <- await_socket(socket_path, leader, opts),
         {:ok, bridge} <- spawn_bridge(executable, cwd, socket_path) do
      send(caller, {:grok_acp_transport_started, ref, :ok})
      transport_loop(owner, ref, leader, bridge)
    else
      {:error, reason} ->
        send(caller, {:grok_acp_transport_started, ref, {:error, reason}})
    end
  end

  defp prepare_leader(executable, cwd, socket_path, opts) when is_list(opts) do
    case Keyword.get(opts, :leader_mode, :start) do
      :attach -> {:ok, nil}
      :start -> spawn_leader(executable, cwd, socket_path)
      _other -> {:error, :invalid_leader_mode}
    end
  end

  defp spawn_leader(executable, cwd, socket_path) do
    argv = [
      executable,
      "--leader-socket",
      socket_path,
      "agent",
      "leader",
      "--no-exit-on-disconnect",
      "--relay-on-demand",
      "--no-auto-update"
    ]

    spawn_process(argv, cwd, :leader, false)
  end

  defp spawn_bridge(executable, cwd, socket_path) do
    argv = [
      executable,
      "--leader-socket",
      socket_path,
      "agent",
      "--leader",
      "stdio"
    ]

    spawn_process(argv, cwd, :bridge, true)
  end

  defp spawn_process(argv, cwd, role, stdin?) do
    receiver = self()

    stdout = fn _stream, _ospid, data -> send(receiver, {:stream, role, :stdout, data}) end
    stderr = fn _stream, _ospid, data -> send(receiver, {:stream, role, :stderr, data}) end

    opts = [
      :monitor,
      {:cd, to_charlist(cwd)},
      {:stdout, stdout},
      {:stderr, stderr}
    ]

    opts = if stdin?, do: [:stdin | opts], else: opts
    command = Enum.map(argv, &to_charlist/1)

    case :exec.run(command, opts) do
      {:ok, exec_pid, ospid} ->
        {:ok, %{exec_pid: exec_pid, ospid: ospid, role: role}}

      {:error, reason} ->
        {:error, {:spawn_failed, role, reason}}
    end
  end

  defp await_socket(socket_path, leader, opts) do
    timeout_ms = Keyword.get(opts, :leader_timeout_ms, @default_leader_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_socket_loop(socket_path, leader, deadline)
  end

  defp await_socket_loop(socket_path, leader, deadline) when not is_nil(leader) do
    cond do
      File.exists?(socket_path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        stop_process(leader)
        {:error, {:leader_socket_timeout, socket_path}}

      true ->
        receive do
          {:DOWN, ospid, :process, exec_pid, _reason}
          when ospid == leader.ospid and exec_pid == leader.exec_pid ->
            # A competing leader may have won the lock. Give its socket the
            # remainder of the bounded readiness window before failing.
            await_socket_loop(socket_path, nil, deadline)
        after
          @socket_poll_ms -> await_socket_loop(socket_path, leader, deadline)
        end
    end
  end

  defp await_socket_loop(socket_path, nil, deadline) do
    if File.exists?(socket_path) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, {:leader_socket_timeout, socket_path}}
      else
        receive do
        after
          @socket_poll_ms -> await_socket_loop(socket_path, nil, deadline)
        end
      end
    end
  end

  defp transport_loop(owner, ref, leader, bridge) do
    receive do
      {:write, data} ->
        case :exec.send(bridge.ospid, data) do
          :ok -> transport_loop(owner, ref, leader, bridge)
          error -> send(owner, {:grok_acp_transport, :exit, {:write_failed, error}})
        end

      {:stream, :bridge, :stdout, data} ->
        send(owner, {:grok_acp_transport, :stdout, data})
        transport_loop(owner, ref, leader, bridge)

      {:stream, role, :stderr, data} when role in [:leader, :bridge] ->
        send(owner, {:grok_acp_transport, :stderr, role, data})
        transport_loop(owner, ref, leader, bridge)

      {:stream, :leader, :stdout, _data} ->
        transport_loop(owner, ref, leader, bridge)

      {:DOWN, ospid, :process, exec_pid, reason}
      when ospid == bridge.ospid and exec_pid == bridge.exec_pid ->
        stop_process(leader)
        send(owner, {:grok_acp_transport, :exit, {:bridge_exit, exit_code(reason)}})

      {:DOWN, ospid, :process, exec_pid, _reason}
      when not is_nil(leader) and ospid == leader.ospid and exec_pid == leader.exec_pid ->
        # This is expected when the command discovered an existing leader and
        # lost Grok's lock race. The attached stdio bridge remains authoritative.
        transport_loop(owner, ref, nil, bridge)

      :stop ->
        stop_process(bridge)
        stop_process(leader)

      {:EXIT, ^owner, _reason} ->
        stop_process(bridge)
        stop_process(leader)

      _other ->
        transport_loop(owner, ref, leader, bridge)
    end
  end

  defp stop_process(nil), do: :ok

  defp stop_process(%{ospid: ospid}) do
    _ = :exec.send(ospid, :eof)
    _ = :exec.kill(ospid, 15)
    :ok
  end

  defp exit_code({:exit_status, status}) when is_integer(status) do
    if status >= 256, do: Bitwise.bsr(status, 8), else: status
  end

  defp exit_code(reason), do: reason

  defp resolve_executable(opts) do
    case Keyword.get(opts, :grok_executable) || System.find_executable("grok") do
      executable when is_binary(executable) and executable != "" -> {:ok, executable}
      _ -> {:error, :grok_not_found}
    end
  end

  defp resolve_cwd(opts) do
    case Keyword.get(opts, :cwd) do
      cwd when is_binary(cwd) and cwd != "" -> {:ok, cwd}
      _ -> {:error, :invalid_cwd}
    end
  end

  defp resolve_socket_path(opts) do
    socket_path =
      Keyword.get_lazy(opts, :leader_socket, fn ->
        Path.join([System.user_home!(), ".grok", "leader.sock"])
      end)

    case socket_path do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, :invalid_leader_socket}
    end
  end

  defp ensure_socket_parent(socket_path) do
    if File.dir?(Path.dirname(socket_path)) do
      :ok
    else
      {:error, :leader_socket_parent_missing}
    end
  end
end
