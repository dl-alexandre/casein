defmodule DevIDE.Assignments.ProjectionStore do
  @moduledoc """
  Behaviour for assignment projection caching.

  Projections are disposable artifacts derived from the event stream.
  Rebuilding from events must always produce the same result.
  """

  alias DevIDE.Assignments.Assignment

  @callback put(String.t(), Assignment.t()) :: :ok
  @callback get(String.t()) :: {:ok, Assignment.t()} | :error
  @callback list(keyword()) :: [Assignment.t()]
  @callback clear() :: :ok
end
