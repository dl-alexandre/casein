defmodule DevIDE.Audit.Event do
  @moduledoc """
  Single audit record structure that maps 1:1 to the `audit_events` database table.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          workspace_id: String.t() | nil,
          actor_id: String.t() | nil,
          action: String.t(),
          target_type: String.t() | nil,
          target_ref: String.t() | nil,
          decision: :allow | :deny | nil,
          reason: atom() | nil,
          metadata: map(),
          inserted_at: DateTime.t()
        }

  @enforce_keys [:id, :action, :inserted_at]
  defstruct [
    :id,
    :workspace_id,
    :actor_id,
    :action,
    :target_type,
    :target_ref,
    :decision,
    :reason,
    :inserted_at,
    metadata: %{}
  ]

  def new(attrs) do
    struct!(
      __MODULE__,
      Map.merge(
        %{id: Ecto.UUID.generate(), inserted_at: DateTime.utc_now()},
        attrs
      )
    )
  end
end
