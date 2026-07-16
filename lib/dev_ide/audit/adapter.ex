defmodule DevIDE.Audit.Adapter do
  @moduledoc "Behaviour for audit event persistence adapters."

  alias DevIDE.Audit.Event

  @callback record(Event.t()) :: :ok | {:error, term()}
  @callback list(opts :: keyword()) :: [Event.t()]
  @callback recent_for(workspace_id :: String.t() | nil, n :: pos_integer()) :: [Event.t()]
  @callback recent_with_action_prefix(
              workspace_id :: String.t() | nil,
              action_prefix :: String.t(),
              n :: pos_integer()
            ) :: [Event.t()]
  @callback recent_for_tool(
              workspace_id :: String.t(),
              tool :: String.t(),
              n :: pos_integer()
            ) :: [Event.t()]
  @callback list_by_correlation(correlation_id :: String.t()) :: [Event.t()]
  @callback clear() :: :ok
end
