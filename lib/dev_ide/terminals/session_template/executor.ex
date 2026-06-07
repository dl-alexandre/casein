defmodule DevIDE.Terminals.SessionTemplate.Executor do
  @moduledoc """
  Execution boundary for session templates.

  M2.0 only supports dry-runs. Real tmux execution will be added behind this
  module so callers do not need to know whether a template is being planned or
  applied.
  """

  alias DevIDE.Terminals.SessionTemplate
  alias DevIDE.Terminals.SessionTemplate.Planner

  @spec plan(String.t() | SessionTemplate.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def plan(template_or_id, opts \\ []), do: Planner.plan(template_or_id, opts)

  @spec dry_run(String.t() | SessionTemplate.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def dry_run(template_or_id, opts \\ []), do: Planner.dry_run(template_or_id, opts)
end
