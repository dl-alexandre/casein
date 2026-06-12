defmodule McpCtl do
  @moduledoc """
  Shared MCP tool schema helpers for agent-facing JSON tool definitions.

  `McpCtl.Params`, `McpCtl.Tool`, and `McpCtl.Error` are reusable across
  hosts. DevIDE-specific tool implementations remain in `DevIDE.Agents.*Tools`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
