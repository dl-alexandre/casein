defmodule DevIDE.Audit.Adapter do
  @moduledoc "Behaviour for audit event persistence adapters."

  alias DevIDE.Audit.Event

  @callback record(Event.t()) :: :ok | {:error, term()}
  @callback list(opts :: keyword()) :: [Event.t()]
  @callback recent_for(workspace_id :: String.t() | nil, n :: pos_integer()) :: [Event.t()]
  @callback clear() :: :ok
end
