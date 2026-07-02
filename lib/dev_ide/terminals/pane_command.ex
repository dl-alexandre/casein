defmodule DevIDE.Terminals.PaneCommand do
  @moduledoc """
  Structured command record extracted from terminal shell-integration marks.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          workspace_id: String.t(),
          sid: String.t(),
          pane_id: String.t() | nil,
          seq: pos_integer(),
          command: String.t() | nil,
          cwd: String.t() | nil,
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          exit_status: integer() | nil,
          output: binary(),
          output_truncated?: boolean(),
          gen_range: {pos_integer(), pos_integer()} | nil
        }

  defstruct [
    :id,
    :workspace_id,
    :sid,
    :pane_id,
    :seq,
    :command,
    :cwd,
    :started_at,
    :ended_at,
    :exit_status,
    :gen_range,
    output: "",
    output_truncated?: false
  ]
end
