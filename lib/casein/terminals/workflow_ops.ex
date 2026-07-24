defmodule Casein.Terminals.WorkflowOps do
  @moduledoc false

  alias Casein.Terminals.Workflows

  @doc "Lists terminal workflow specs for a workspace."
  @spec workflow_specs(String.t()) :: [Workflows.spec()]
  def workflow_specs(workspace_id) do
    Workflows.list_specs(workspace_id)
  end

  @doc "True when a workflow spec can run from the palette without extra arguments."
  @spec workflow_palette_runnable?(Workflows.spec()) :: boolean()
  def workflow_palette_runnable?(spec) do
    Workflows.palette_runnable?(spec)
  end

  @doc "Encoded terminal workflow command id using default placeholder bindings."
  @spec workflow_command_id(Workflows.spec()) :: String.t()
  def workflow_command_id(spec) do
    Workflows.command_id(spec)
  end
end
