defmodule Casein.Proposals do
  @moduledoc """
  Read-only proposal review.

  Proposals are agent-produced artifacts (currently unified `.diff`/`.patch`
  files) discovered under known workspace dirs. This module surfaces them
  for human review only — there is no callback for applying, writing, or
  granting permissions, by design.
  """

  alias Casein.Proposals.{Analysis, ConflictAnalyzer}

  def discover(root), do: impl().discover(root)
  def parse(root, rel_path), do: impl().parse(root, rel_path)
  def analyze(root, proposal), do: ConflictAnalyzer.analyze(root, proposal)
  def invalid_analysis, do: %Analysis{risk: :invalid}

  defp impl, do: Application.get_env(:dev_ide, :proposals_adapter, Casein.Proposals.LocalAdapter)
end
