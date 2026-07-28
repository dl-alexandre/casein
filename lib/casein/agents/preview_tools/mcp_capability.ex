defmodule Casein.Agents.PreviewTools.MCPCapability do
  @moduledoc """
  Detects the Casein-hosted preview-control MCP endpoint.

  The endpoint is served by the web layer, but capability detection lives in
  context code. The base URL is resolved through a configured MFA to keep that
  dependency inverted.
  """

  alias Casein.Agents.{Capability, PreviewTools}
  alias Casein.Previews.Deps

  @spec detect() :: Capability.t()
  def detect do
    case Deps.impl(:urls).preview_url() do
      url when is_binary(url) and url != "" ->
        %Capability{
          kind: :preview_mcp,
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
        %Capability{kind: :preview_mcp, status: :missing}
    end
  end

  defp tool_names do
    PreviewTools.definitions()
    |> Enum.map(& &1.name)
  end
end
