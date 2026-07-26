defmodule CaseinMob.DeviceBridge do
  @moduledoc """
  Device-side registry for the host bridge process.

  `CaseinMob.HostBridge` runs on the devbox and announces its pid to this
  process. Screens use the registered pid for non-terminal IDE requests, while
  terminal bytes still flow directly to `CaseinMob.TerminalScreen`.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec put_host(pid()) :: :ok
  def put_host(host) when is_pid(host), do: GenServer.cast(__MODULE__, {:put_host, host})

  @spec host() :: {:ok, pid()} | :error
  def host do
    GenServer.call(__MODULE__, :host)
  catch
    :exit, _ -> :error
  end

  @impl true
  def init(_opts), do: {:ok, %{host: nil}}

  @impl true
  def handle_call(:host, _from, %{host: host} = state) when is_pid(host),
    do: {:reply, {:ok, host}, state}

  def handle_call(:host, _from, state), do: {:reply, :error, state}

  @impl true
  def handle_cast({:put_host, host}, state) when is_pid(host),
    do: {:noreply, %{state | host: host}}

  @impl true
  def handle_info({:vt_host, host}, state) when is_pid(host),
    do: {:noreply, %{state | host: host}}

  def handle_info(_message, state), do: {:noreply, state}
end
