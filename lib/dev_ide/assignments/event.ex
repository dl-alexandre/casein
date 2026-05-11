defmodule DevIDE.Assignments.Event do
  @moduledoc """
  Source-of-truth event for the assignment event stream.

  Events are append-only and monotonically sequenced per assignment.
  The `%Assignment{}` projection is a derived view produced by
  `DevIDE.Assignments.Reducer`.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          assignment_id: String.t(),
          sequence: pos_integer(),
          type: atom(),
          actor: String.t() | nil,
          occurred_at: DateTime.t(),
          payload: map()
        }

  defstruct [:id, :assignment_id, :sequence, :type, :actor, :occurred_at, :payload]
end
