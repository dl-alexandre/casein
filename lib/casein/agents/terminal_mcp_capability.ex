defmodule Casein.Agents.TerminalMCPCapability do
  @moduledoc """
  Detects the Casein-hosted terminal-control MCP endpoint.

  The endpoint is served by the web layer, but capability detection lives in
  context code. The base URL is resolved through a configured MFA to keep that
  dependency inverted — mirrors `Casein.Agents.PreviewTools.MCPCapability`.
  """

  alias Casein.Agents.{Capability, MCPUrls, TerminalTools}

  @spec detect() :: Capability.t()
  def detect do
    case MCPUrls.terminal_url() do
      url when is_binary(url) and url != "" ->
        %Capability{
          kind: :terminal_mcp,
          status: :detected,
          source: :casein,
          url: url,
          details: %{
            transport: "http_json_rpc",
            auth_type: "bearer",
            tools: tool_names()
          }
        }

      _ ->
        %Capability{kind: :terminal_mcp, status: :missing}
    end
  end

  defp tool_names do
    TerminalTools.definitions()
    |> Enum.map(& &1.name)
  end
end
