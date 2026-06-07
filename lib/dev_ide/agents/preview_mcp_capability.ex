defmodule DevIDE.Agents.PreviewMCPCapability do
  @moduledoc """
  Detects the DevIDE-hosted preview-control MCP endpoint.

  The endpoint is served by the web layer, but capability detection lives in
  context code. The base URL is resolved through a configured MFA to keep that
  dependency inverted.
  """

  alias DevIDE.Agents.{Capability, PreviewTools}

  @spec detect() :: Capability.t()
  def detect do
    case base_url() do
      url when is_binary(url) ->
        %Capability{
          kind: :preview_mcp,
          status: :detected,
          source: :dev_ide,
          url: preview_mcp_url(url),
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

  defp base_url do
    with {mod, fun, args} <- Application.get_env(:dev_ide, :preview_mcp_url_provider),
         true <- Code.ensure_loaded?(mod),
         url when is_binary(url) <- apply(mod, fun, args) do
      url
    else
      _ -> nil
    end
  end

  defp preview_mcp_url(url), do: String.trim_trailing(url, "/") <> "/api/preview/mcp"

  defp tool_names do
    PreviewTools.definitions()
    |> Enum.map(& &1.name)
  end
end
