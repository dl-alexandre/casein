defmodule DevIDE.Codex.Store.Adapter do
  @moduledoc false

  alias DevIDE.Codex.Event

  @callback record(Event.t()) :: :ok | {:error, term()}
  @callback latest_sequence(String.t()) :: non_neg_integer()
  @callback workspace_snapshot(String.t(), keyword()) :: map()
  @callback timeline(String.t(), String.t(), keyword()) :: [Event.t()]
  @callback clear() :: :ok
end
