defmodule DevIDE.Signals.AlertsRouter do
  @moduledoc """
  Subscribes to audit-derived signals on `DevIDE.SignalBus` and routes
  alert-worthy events to `DevIDE.Push.Dispatcher`.

  In-app alert delivery (`DevIdeWeb.SessionChannel`) still listens to the
  audit PubSub spine directly; this router owns the OS-push path so the two
  surfaces stay aligned via `DevIDE.Alerts` without duplicating filter logic
  on raw audit messages in the dispatcher.
  """

  use GenServer

  alias DevIDE.Alerts
  alias DevIDE.Audit.Event
  alias DevIDE.Push.Dispatcher
  alias DevIDE.SignalBus
  alias DevIDE.Signals.Publish
  alias Jido.Signal
  alias Jido.Signal.Bus

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{watched: MapSet.new()}, name: __MODULE__)
  end

  @doc """
  Track a workspace for alert push delivery (idempotent).

  Called when a push token is registered for a workspace so alert signals
  are only pushed where a device is listening.
  """
  @spec watch(String.t()) :: :ok
  def watch(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:watch, workspace_id})
  end

  @impl true
  def init(state) do
    if signal_bus_enabled?() do
      {:ok, _sub_id} =
        Bus.subscribe(SignalBus.name(), Publish.audit_subscription_pattern(),
          dispatch: {:pid, target: self()}
        )
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:watch, workspace_id}, _from, %{watched: watched} = state) do
    {:reply, :ok, %{state | watched: MapSet.put(watched, workspace_id)}}
  end

  @impl true
  def handle_info({:signal, %Signal{} = signal}, %{watched: watched} = state) do
    event = Event.from_signal(signal)

    if route_alert?(event, watched) do
      :ok = Dispatcher.deliver_audit_alert(event)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp route_alert?(%Event{action: "run.approval_requested"}, _watched), do: false

  defp route_alert?(%Event{workspace_id: workspace_id} = event, watched)
       when is_binary(workspace_id) do
    MapSet.member?(watched, workspace_id) and Alerts.alert?(event)
  end

  defp route_alert?(_event, _watched), do: false

  defp signal_bus_enabled? do
    Application.get_env(:dev_ide, :signal_bus_enabled, true)
  end
end
