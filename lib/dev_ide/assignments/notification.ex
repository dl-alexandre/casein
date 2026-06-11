defmodule DevIDE.Assignments.Notification do
  @moduledoc """
  Canonical shape for assignment change notifications.

  Broadcast **after** the projection is committed to the store.
  Subscribers receive this, not raw events, so that every consumer
  sees the same derived state.

  Do not treat PubSub as a source of truth — events remain the
  durable authority.  Subscriptions are ephemeral views.
  """

  @type t :: %__MODULE__{
          assignment_id: String.t(),
          event_type: atom(),
          sequence: pos_integer(),
          projection: DevIDE.Assignments.Assignment.t(),
          occurred_at: DateTime.t(),
          event: DevIDE.Assignments.Event.t() | nil
        }

  defstruct [:assignment_id, :event_type, :sequence, :projection, :occurred_at, :event]
end
