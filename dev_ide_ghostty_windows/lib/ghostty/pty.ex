defmodule Ghostty.PTY do
  @moduledoc """
  Windows-compatible persistent process transport implementing Ghostty's PTY API.

  Uses Windows ConPTY for a real pseudo-console, with raw terminal bytes on one
  loopback socket and resize/lifecycle messages on a second control socket.
  """

  use GenServer

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, Keyword.put(init_opts, :owner, self()), server_opts)
  end

  def write(pty, data), do: GenServer.call(pty, {:write, IO.iodata_to_binary(data)})
  def resize(pty, cols, rows), do: GenServer.call(pty, {:resize, cols, rows})
  def close(pty), do: GenServer.stop(pty)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    {child_command, child_args} = child_command_and_args(opts)

    {:ok, data_listener} = listen()
    {:ok, control_listener} = listen()
    {:ok, {_address, data_port}} = :inet.sockname(data_listener)
    {:ok, {_address, control_port}} = :inet.sockname(control_listener)
    bridge_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    bridge_shell = default_shell()
    bridge = Application.app_dir(:ghostty, "priv/powershell_bridge.ps1")

    args =
      [
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        bridge,
        Integer.to_string(data_port),
        Integer.to_string(control_port),
        bridge_token,
        Integer.to_string(cols),
        Integer.to_string(rows),
        cwd,
        child_command
      ] ++ child_args

    port =
      Port.open({:spawn_executable, to_charlist(bridge_shell)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, Enum.map(args, &to_charlist/1)}
      ])

    with {:ok, data_socket} <- accept_authenticated(data_listener, bridge_token),
         {:ok, control_socket} <- accept_authenticated(control_listener, bridge_token) do
      :ok = :gen_tcp.close(data_listener)
      :ok = :gen_tcp.close(control_listener)
      :ok = :inet.setopts(data_socket, active: true)
      :ok = :inet.setopts(control_socket, active: true)

      {:ok,
       %{
         port: port,
         data_socket: data_socket,
         control_socket: control_socket,
         owner: owner
       }}
    else
      {:error, reason} ->
        Port.close(port)
        :gen_tcp.close(data_listener)
        :gen_tcp.close(control_listener)
        {:stop, {:bridge_connect_failed, reason}}
    end
  rescue
    error -> {:stop, {:process_open_failed, Exception.message(error)}}
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    :ok = :gen_tcp.send(state.data_socket, data)
    {:reply, :ok, state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    :ok = :gen_tcp.send(state.control_socket, "resize #{cols} #{rows}\n")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{data_socket: socket} = state) do
    send(state.owner, {:data, data})
    {:noreply, state}
  end

  def handle_info({:tcp, socket, _data}, %{control_socket: socket} = state), do: {:noreply, state}

  def handle_info({:tcp_closed, socket}, %{data_socket: socket} = state) do
    send(state.owner, {:exit, 0})
    {:stop, :normal, state}
  end

  def handle_info({:tcp_closed, socket}, %{control_socket: socket} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{data_socket: socket} = state) do
    send(state.owner, {:exit, reason})
    {:stop, {:tcp_error, reason}, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{control_socket: socket} = state) do
    {:stop, {:control_tcp_error, reason}, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:exit, status})
    {:stop, :normal, state}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    send(state.owner, {:bridge_error, data})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port, data_socket: data_socket, control_socket: control_socket}) do
    _ = :gen_tcp.send(control_socket, "close\n")
    :gen_tcp.close(data_socket)
    :gen_tcp.close(control_socket)
    if Port.info(port), do: Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp default_shell do
    System.find_executable("pwsh") ||
      System.find_executable("powershell.exe") ||
      System.find_executable("cmd.exe") ||
      raise "PowerShell or cmd.exe was not found"
  end

  defp child_command_and_args(opts) do
    case Keyword.get(opts, :cmd) do
      nil ->
        {default_shell(),
         ["-NoLogo", "-NoProfile", "-NoExit", "-Command", "Remove-Module PSReadLine"]}

      command ->
        {command, Keyword.get(opts, :args, [])}
    end
  end

  defp listen do
    :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])
  end

  # Loopback is an address boundary, not an authorization boundary. A fresh,
  # per-bridge capability prevents another local process from claiming either
  # transport socket before the PowerShell bridge does.
  defp accept_authenticated(listener, token, deadline \\ System.monotonic_time(:millisecond) + 15_000) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :auth_timeout}
    else
      with {:ok, socket} <- :gen_tcp.accept(listener, remaining),
           {:ok, supplied} <- :gen_tcp.recv(socket, byte_size(token), remaining) do
        if :crypto.hash_equals(supplied, token) do
          {:ok, socket}
        else
          :gen_tcp.close(socket)
          accept_authenticated(listener, token, deadline)
        end
      else
        {:error, :closed} -> accept_authenticated(listener, token, deadline)
        other -> other
      end
    end
  end
end
