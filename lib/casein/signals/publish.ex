defmodule Casein.Signals.Publish do
  @moduledoc false

  alias Casein.Agents.AgentEvent
  alias Casein.Audit.Event
  alias Casein.SignalBus
  alias Casein.Signals
  alias Jido.Signal.Bus

  @audit_pattern Casein.Signals.type_prefix() <> "**"
  @domain_pattern Casein.Signals.domain_type("**")

  @spec audit_event(Event.t()) :: :ok
  def audit_event(%Event{} = event) do
    if enabled?() do
      signal = Signals.from_audit_event(event)

      case Bus.publish(SignalBus.name(), [signal]) do
        {:ok, _count} ->
          :telemetry.execute(
            [:casein, :signals, :publish],
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

  @spec agent_event(AgentEvent.t()) :: :ok
  def agent_event(%AgentEvent{} = event) do
    if enabled?() do
      signal = Signals.from_agent_event(event)

      case Bus.publish(SignalBus.name(), [signal]) do
        {:ok, _count} ->
          :telemetry.execute(
            [:casein, :signals, :publish],
            %{count: 1},
            %{
              action: event.event_type,
              workspace_id: event.workspace_id,
              agent_event: true
            }
          )

          :ok

        {:error, reason} ->
          require Logger

          Logger.warning(
            "signal bus publish failed for agent event #{event.event_type}: #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  @doc false
  @spec audit_subscription_pattern() :: String.t()
  def audit_subscription_pattern, do: @audit_pattern

  @doc false
  @spec domain_subscription_pattern() :: String.t()
  def domain_subscription_pattern, do: @domain_pattern

  @doc """
  Publish a domain event (deploy/runtime/etc.) to the signal bus.

  Additive alongside existing Phoenix.PubSub topics — does not replace them.
  """
  @spec domain_event(String.t(), map(), keyword()) :: :ok
  def domain_event(event, data, opts \\ []) when is_binary(event) and is_map(data) do
    if enabled?() do
      signal = Signals.from_domain_event(event, data, opts)

      case Bus.publish(SignalBus.name(), [signal]) do
        {:ok, _count} ->
          :telemetry.execute(
            [:casein, :signals, :publish],
            %{count: 1},
            %{action: event, workspace_id: Keyword.get(opts, :workspace_id), domain: true}
          )

          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("signal bus domain publish failed for #{event}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp enabled? do
    Application.get_env(:casein, :signal_bus_enabled, true)
  end
end
