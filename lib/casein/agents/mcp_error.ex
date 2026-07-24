defmodule Casein.Agents.MCPError do
  @moduledoc """
  Normalizes agent tool errors into MCP-friendly structured payloads.

  Tool handlers return `{:error, reason}` where `reason` may be an atom or a
  map with `:error`, `:message`, and optional context fields. This module turns
  those into consistent `structuredContent` maps for MCP clients.
  """

  defdelegate format(reason), to: McpCtl.Error
  defdelegate summary(reason), to: McpCtl.Error
  defdelegate tool_result(reason), to: McpCtl.Error
end
