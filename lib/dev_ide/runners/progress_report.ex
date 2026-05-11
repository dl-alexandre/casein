defmodule DevIDE.Runners.ProgressReport do
  @moduledoc "Append-only progress or terminal evidence for a runner assignment."

  @type t :: %__MODULE__{
          id: String.t() | nil,
          assignment_id: String.t(),
          client_report_id: String.t() | nil,
          runner_id: String.t(),
          position: pos_integer(),
          event: String.t(),
          stream: String.t() | nil,
          message: String.t() | nil,
          data: String.t() | nil,
          data_truncated: boolean(),
          evidence: map(),
          observed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :assignment_id, :runner_id, :position, :event]
  defstruct [
    :id,
    :assignment_id,
    :client_report_id,
    :runner_id,
    :position,
    :event,
    :stream,
    :message,
    :data,
    :observed_at,
    :inserted_at,
    data_truncated: false,
    evidence: %{}
  ]
end
