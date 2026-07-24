defmodule Casein.Agents.ArtifactTools do
  @moduledoc """
  Agent-facing artifact project operations.

  These tools are intentionally a thin wrapper around `Casein.ArtifactProjects`:
  agents create and edit isolated Git worktree-backed artifacts here, then hand
  the returned `preview_open_arguments` to Preview MCP when they need a visible
  browser pane.

  Each tool is a `Jido.Action` module under `Casein.Agents.ArtifactTools.*`,
  invoked through `Casein.Agents.ToolAction`: params are schema-validated at
  runtime while the MCP wire shapes (tools/list JSON Schema, error
  structuredContent) stay exactly as before.
  """

  alias Casein.Agents.ArtifactTools.{Create, Get, List, Serve, Snapshot, Update}
  alias Casein.Agents.ToolAction

  @type tool :: McpCtl.Tool.t()

  @actions [Create, Update, List, Get, Serve, Snapshot]
  @by_name Map.new(@actions, &{&1.name(), &1})

  @doc "Tool definitions exposed to agent runtimes."
  @spec definitions() :: [tool()]
  def definitions, do: Enum.map(@actions, &ToolAction.definition/1)

  @doc "Invoke an artifact tool by MCP tool name."
  @spec invoke(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(name, args) when is_binary(name) and is_map(args) do
    case Map.fetch(@by_name, name) do
      {:ok, action} -> ToolAction.invoke(action, args)
      :error -> {:error, :unknown_tool}
    end
  end

  def invoke(_name, _args), do: {:error, :unknown_tool}
end
