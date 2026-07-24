defmodule Casein.Runtimes.LifecycleEvent do
  @moduledoc "Append-only runtime lifecycle event."

  @type t :: %__MODULE__{
          id: String.t() | nil,
          runtime_id: String.t(),
          workspace_id: String.t(),
          event: String.t(),
          from_status: String.t() | nil,
          to_status: String.t(),
          actor_id: String.t() | nil,
          assignment_id: String.t() | nil,
          runner_id: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :runtime_id, :workspace_id, :event, :to_status, :inserted_at]
  defstruct [
    :id,
    :runtime_id,
    :workspace_id,
    :event,
    :from_status,
    :to_status,
    :actor_id,
    :assignment_id,
    :runner_id,
    :inserted_at,
    metadata: %{}
  ]
end
