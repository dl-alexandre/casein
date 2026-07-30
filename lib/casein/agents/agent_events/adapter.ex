defmodule Casein.Agents.AgentEvents.Adapter do
  @moduledoc false

  alias Casein.Agents.AgentEvent

  @callback record(map()) ::
              {:ok, AgentEvent.t(), :inserted | :duplicate} | {:error, term()}
  @callback recent_for(String.t(), keyword()) :: [AgentEvent.t()]
  @callback replay(String.t(), DateTime.t() | nil, String.t() | nil, keyword()) ::
              [AgentEvent.t()]
  @callback list_for_session(String.t(), String.t(), keyword()) :: [AgentEvent.t()]
  @callback list_by_event_types(String.t(), [String.t()]) :: [AgentEvent.t()]
  @callback list_open_clarifications(String.t(), String.t(), String.t(), keyword()) ::
              [AgentEvent.t()]
  @callback list_by_correlation(String.t(), keyword()) :: [AgentEvent.t()]
  @callback clear() :: :ok
end
