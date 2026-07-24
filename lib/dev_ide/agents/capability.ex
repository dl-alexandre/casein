defmodule Casein.Agents.Capability do
  @moduledoc """
  A single observed agent capability for a workspace. Always read-only in M7;
  the struct does not carry any actions.
  """

  @type kind ::
          :opencode
          | :tidewave
          | :artifact_mcp
          | :preview_mcp
          | :terminal_mcp
          | :fff
          | :browser_artifacts
          | :transcripts
  @type status :: :detected | :missing
  @type source :: :manager | :workspace_fs | :config | :dev_ide | :preview_env

  @type t :: %__MODULE__{
          kind: kind(),
          status: status(),
          source: source() | nil,
          path: String.t() | nil,
          url: String.t() | nil,
          mtime: NaiveDateTime.t() | nil,
          details: map()
        }

  defstruct [:kind, :status, :source, :path, :url, :mtime, details: %{}]
end
