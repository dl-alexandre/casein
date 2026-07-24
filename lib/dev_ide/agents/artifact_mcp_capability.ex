defmodule Casein.Agents.ArtifactMCPCapability do
  @moduledoc """
  Detects the Casein-hosted artifact-project MCP endpoint.
  """

  alias Casein.Agents.{ArtifactTools, Capability, MCPUrls}

  @spec detect() :: Capability.t()
  def detect do
    case MCPUrls.artifact_url() do
      url when is_binary(url) and url != "" ->
        %Capability{
          kind: :artifact_mcp,
          status: :detected,
          source: :dev_ide,
          url: url,
          details: %{
            transport: "http_json_rpc",
            auth_type: "bearer",
            tools: tool_names()
          }
        }

      _ ->
        %Capability{kind: :artifact_mcp, status: :missing}
    end
  end

  defp tool_names do
    ArtifactTools.definitions()
    |> Enum.map(& &1.name)
  end
end
