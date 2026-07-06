defmodule DevIDE.Agents.AnnotationTools do
  @moduledoc """
  Workspace annotation tools for the Terminal MCP endpoint.

  Agents propose structured notes for human review; listing is read-only.

  Each tool is a `Jido.Action` module under `DevIDE.Agents.AnnotationTools.*`,
  invoked through `DevIDE.Agents.ToolAction`.
  """

  alias DevIDE.Agents.AnnotationTools.{Impl, List, Propose}
  alias DevIDE.Agents.ToolAction

  @type tool :: McpCtl.Tool.t()

  @actions [List, Propose]
  @by_name Map.new(@actions, &{&1.name(), &1})

  @doc "MCP tool definitions for workspace annotations."
  @spec definitions() :: [tool()]
  def definitions, do: Enum.map(@actions, &ToolAction.definition/1)

  @spec invoke(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(tool_name, params) when is_map(params) do
    case Map.fetch(@by_name, tool_name) do
      {:ok, action} -> ToolAction.invoke(action, params)
      :error -> {:error, :unknown_tool}
    end
  end

  defdelegate list(params), to: Impl
  defdelegate propose(params), to: Impl
end
