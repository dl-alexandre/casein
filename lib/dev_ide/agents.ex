defmodule DevIDE.Agents do
  @moduledoc """
  Read-only agent capability detection for a workspace.

  M7 contract: this module **observes** agent state and never starts agents,
  sends prompts, or grants permissions. Every public function is a query.
  Adapters implementing the behaviour follow the same rule.
  """

  alias DevIDE.Agents.{Capability, Artifact, ReviewCommand}

  @callback detect(root :: String.t(), manager_workspace :: map() | nil) :: [Capability.t()]
  @callback transcripts(root :: String.t()) :: [Artifact.t()]
  @callback review_commands(caps :: [Capability.t()]) :: [ReviewCommand.t()]

  def detect(root, ws \\ nil), do: impl().detect(root, ws)
  def transcripts(root), do: impl().transcripts(root)
  def review_commands(caps), do: impl().review_commands(caps)

  defp impl, do: Application.get_env(:dev_ide, :agents_adapter, DevIDE.Agents.LocalAdapter)
end
