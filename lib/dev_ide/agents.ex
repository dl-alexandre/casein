defmodule Casein.Agents do
  @moduledoc """
  Public API for agent capability detection and agent-owned tool surfaces.

  M7 contract: adapter-backed functions **observe** agent state and never start
  agents, send prompts, or grant permissions. Adapters implementing the
  behaviour follow the same rule. Agent-owned tool helpers are exposed here as
  explicit facade calls so web code does not reach into tool internals.
  """

  alias Casein.Agents.{Capability, Artifact, PreviewTools, ReviewCommand}

  @callback detect(root :: String.t(), manager_workspace :: map() | nil) :: [Capability.t()]
  @callback transcripts(root :: String.t()) :: [Artifact.t()]
  @callback review_commands(caps :: [Capability.t()]) :: [ReviewCommand.t()]

  def detect(root, ws \\ nil), do: impl().detect(root, ws)
  def transcripts(root), do: impl().transcripts(root)
  def review_commands(caps), do: impl().review_commands(caps)

  @doc "Splits the active tmux window and opens a preview pane for the given URL."
  @spec split_preview_pane(map(), String.t(), keyword()) ::
          {:ok, %{pane_id: String.t(), session: struct()}} | {:error, term()}
  def split_preview_pane(workspace, url, opts) do
    PreviewTools.split_preview_pane(workspace, url, opts)
  end

  defp impl, do: Application.get_env(:dev_ide, :agents_adapter, Casein.Agents.LocalAdapter)
end
