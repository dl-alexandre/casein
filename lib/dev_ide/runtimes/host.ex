defmodule Casein.Runtimes.Host do
  @moduledoc "Host capability inventory used for runtime placement."

  @type t :: %__MODULE__{
          id: String.t(),
          os: String.t() | nil,
          capabilities: [String.t()],
          tools: [String.t()],
          concurrency_limit: pos_integer(),
          heartbeat_at: DateTime.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @enforce_keys [:id]
  defstruct [
    :id,
    :os,
    :heartbeat_at,
    :inserted_at,
    :updated_at,
    capabilities: [],
    tools: [],
    concurrency_limit: 1,
    metadata: %{}
  ]
end
