defmodule Ghostty.PTY do
  @moduledoc """
  Windows-compatible persistent process transport implementing Ghostty's PTY API.

  This initial transport uses redirected standard streams. It keeps PowerShell
  persistent and interactive for command input/output; a ConPTY implementation
  can replace the internals without changing DevIDE call sites.
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
    {command, args} = command_and_args(opts)
    owner = Keyword.fetch!(opts, :owner)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    {:ok, {_address, port_number}} = :inet.sockname(listener)
    args = args ++ [Integer.to_string(port_number)]

    port =
      Port.open({:spawn_executable, to_charlist(command)}, [
        :binary,
        :exit_status,
        :hide,
        {:args, Enum.map(args, &to_charlist/1)}
      ])

    case :gen_tcp.accept(listener, 10_000) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(listener)
        :ok = :inet.setopts(socket, active: true)
        {:ok, %{port: port, socket: socket, owner: owner}}

      {:error, reason} ->
        Port.close(port)
        :gen_tcp.close(listener)
        {:stop, {:bridge_connect_failed, reason}}
    end
  rescue
    error -> {:stop, {:process_open_failed, Exception.message(error)}}
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    :ok = :gen_tcp.send(state.socket, data)
    {:reply, :ok, state}
  end

  def handle_call({:resize, _cols, _rows}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    send(state.owner, {:data, data})
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    send(state.owner, {:exit, 0})
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    send(state.owner, {:exit, reason})
    {:stop, {:tcp_error, reason}, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:exit, status})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, %{port: port, socket: socket}) do
    :gen_tcp.close(socket)
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

  defp command_and_args(opts) do
    case Keyword.get(opts, :cmd) do
      nil ->
        shell = default_shell()
        bridge = Application.app_dir(:ghostty, "priv/powershell_bridge.ps1")
        {shell, ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", bridge]}

      command ->
        {command, Keyword.get(opts, :args, [])}
    end
  end
end
