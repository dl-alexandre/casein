defmodule Casein.Agents.CodeTools do
  @moduledoc """
  Worktree-scoped code operations for headless workers.

  These tools are a thin Jido/MCP wrapper around existing Casein path safety,
  proposal apply, command allowlist, and policy seams. They do not scrape
  tmux panes or accept a raw shell.
  """

  alias Casein.Agents.CodeTools.{ApplyPatch, Exec, Read, Search}
  alias Casein.Agents.ToolAction

  @type tool :: McpCtl.Tool.t()

  @actions [Read, Search, ApplyPatch, Exec]
  @by_name Map.new(@actions, &{&1.name(), &1})

  @doc "Tool definitions exposed to agent runtimes."
  @spec definitions() :: [tool()]
  def definitions, do: Enum.map(@actions, &ToolAction.definition/1)

  @doc "Invoke a code tool by MCP tool name."
  @spec invoke(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(name, args, context \\ %{})

  def invoke(name, args, context) when is_binary(name) and is_map(args) do
    case Map.fetch(@by_name, name) do
      {:ok, action} -> ToolAction.invoke(action, args, context)
      :error -> {:error, :unknown_tool}
    end
  end

  def invoke(_name, _args, _context), do: {:error, :unknown_tool}
end
