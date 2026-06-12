defmodule McpCtl do
  @moduledoc """
  MCP tool schema fragments shared across DevIDE's agent-facing tools.

  Not a generic MCP library: the parameter descriptions encode DevIDE's
  workspace-id and folder-attachment conventions. It lives outside `DevIDE.*`
  only so tool schema definitions stay dependency-free; tool implementations
  remain in `DevIDE.Agents.*Tools`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
