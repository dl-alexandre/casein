defmodule DevIDE.Workspaces.DbIsolation do
  @moduledoc """
  Snapshot of a workspace's database isolation classification.

  Read-only; produced by `DevIDE.Workspaces.IsolationProbe`. Never carries
  raw credentials — `summary` is the redacted host/port/db form intended
  for UI and audit.
  """

  @type isolation :: :ephemeral | :shared_stage | :local | :unknown | :unsafe
  @type source :: :manager | :env_file | :docker_compose | :default | :none

  @type t :: %__MODULE__{
          isolation: isolation(),
          source: source(),
          summary: String.t() | nil,
          detected_at: DateTime.t() | nil,
          signals: [map()]
        }

  defstruct isolation: :unknown,
            source: :none,
            summary: nil,
            detected_at: nil,
            signals: []
end
