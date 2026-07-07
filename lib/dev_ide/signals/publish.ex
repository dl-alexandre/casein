defmodule DevIDE.Signals.Publish do
  @moduledoc false

  alias DevIDE.Audit.Event
  alias DevIDE.SignalBus
  alias DevIDE.Signals
  alias Jido.Signal.Bus

  @audit_pattern DevIDE.Signals.type_prefix() <> "**"

  @spec audit_event(Event.t()) :: :ok
  def audit_event(%Event{} = event) do
    if enabled?() do
      signal = Signals.from_audit_event(event)

      case Bus.publish(SignalBus.name(), [signal]) do
        {:ok, _count} ->
          :telemetry.execute(
            [:dev_ide, :signals, :publish],
            %{count: 1},
            %{action: event.action, workspace_id: event.workspace_id}
          )

          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("signal bus publish failed for #{event.action}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc false
  @spec audit_subscription_pattern() :: String.t()
  def audit_subscription_pattern, do: @audit_pattern

  defp enabled? do
    Application.get_env(:dev_ide, :signal_bus_enabled, true)
  end
end
