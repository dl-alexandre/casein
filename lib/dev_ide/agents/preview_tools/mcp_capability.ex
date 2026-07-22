defmodule DevIDE.Agents.PreviewTools.MCPCapability do
  @moduledoc """
  Detects the DevIDE-hosted preview-control MCP endpoint.

  The endpoint is served by the web layer, but capability detection lives in
  context code. The base URL is resolved through a configured MFA to keep that
  dependency inverted.
  """

  alias DevIDE.Agents.{Capability, MCPUrls, PreviewTools}

  @spec detect() :: Capability.t()
  def detect do
    case MCPUrls.preview_url() do
      url when is_binary(url) and url != "" ->
        %Capability{
          kind: :preview_mcp,
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
        %Capability{kind: :preview_mcp, status: :missing}
    end
  end

  defp tool_names do
    PreviewTools.definitions()
    |> Enum.map(& &1.name)
  end
end
