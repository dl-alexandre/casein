defmodule DevIDE.Commands.History.Record do
  @moduledoc "Domain struct for a persisted command run."

  @type t :: %__MODULE__{
          id: String.t() | nil,
          workspace_id: String.t(),
          actor_id: String.t() | nil,
          command_id: String.t(),
          argv: [String.t()],
          status: String.t(),
          exit_code: String.t() | nil,
          output: String.t() | nil,
          output_truncated: boolean(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          duration_ms: integer() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :workspace_id,
    :actor_id,
    :command_id,
    :argv,
    :status,
    :exit_code,
    :output,
    :started_at,
    :finished_at,
    :duration_ms,
    :inserted_at,
    :updated_at,
    output_truncated: false,
    metadata: %{}
  ]
end
