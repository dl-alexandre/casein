defmodule DevIDE.Commands.Annotations.Annotation do
  @moduledoc "A single parsed diagnostic from Mix command output."

  @type kind ::
          :compile_error | :compile_warning | :test_failure | :formatter | :generic
  @type severity :: :error | :warning | :info

  @type t :: %__MODULE__{
          kind: kind(),
          severity: severity(),
          file: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          message: String.t() | nil,
          command_id: String.t() | nil,
          stale: boolean()
        }

  defstruct [:kind, :severity, :file, :line, :column, :message, :command_id, stale: false]
end
