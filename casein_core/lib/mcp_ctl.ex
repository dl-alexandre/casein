defmodule McpCtl do
  @moduledoc """
  MCP tool schema fragments shared across Casein's agent-facing tools.

  Not a generic MCP library: the parameter descriptions encode Casein's
  workspace-id and folder-attachment conventions. It lives outside `Casein.*`
  only so tool schema definitions stay dependency-free; tool implementations
  remain in `Casein.Agents.*Tools`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
