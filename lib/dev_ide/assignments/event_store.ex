defmodule DevIDE.Assignments.EventStore do
  @moduledoc """
  Behaviour for append-oriented assignment event storage.

  Events are the durable source of truth.  Projections are derived
  views produced by `DevIDE.Assignments.Reducer`.
  """

  alias DevIDE.Assignments.Event

  @callback append(Event.t()) :: {:ok, Event.t()} | {:error, term()}
  @callback events_for(String.t()) :: [Event.t()]
  @callback list_events(keyword()) :: [Event.t()]
  @callback clear() :: :ok
end
