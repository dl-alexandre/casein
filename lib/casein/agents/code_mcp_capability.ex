defmodule Casein.Agents.CodeMCPCapability do
  @moduledoc """
  Detects the Casein-hosted worktree-scoped Code MCP endpoint.
  """

  alias Casein.Agents.{CodeTools, Capability, MCPUrls}

  @spec detect() :: Capability.t()
  def detect do
    case MCPUrls.code_url() do
      url when is_binary(url) and url != "" ->
        %Capability{
          kind: :code_mcp,
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
        %Capability{kind: :code_mcp, status: :missing}
    end
  end

  defp tool_names do
    CodeTools.definitions()
    |> Enum.map(& &1.name)
  end
end
