defmodule DevIDE.Proposals do
  @moduledoc """
  Read-only proposal review.

  Proposals are agent-produced artifacts (currently unified `.diff`/`.patch`
  files) discovered under known workspace dirs. This module surfaces them
  for human review only — there is no callback for applying, writing, or
  granting permissions, by design.
  """

  alias DevIDE.Proposals.Proposal

  @callback discover(root :: String.t()) :: [Proposal.t()]
  @callback parse(root :: String.t(), rel_path :: String.t()) :: {:ok, Proposal.t()}

  def discover(root), do: impl().discover(root)
  def parse(root, rel_path), do: impl().parse(root, rel_path)

  defp impl, do: Application.get_env(:dev_ide, :proposals_adapter, DevIDE.Proposals.LocalAdapter)
end
