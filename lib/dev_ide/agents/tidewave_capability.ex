defmodule DevIDE.Agents.TidewaveCapability do
  @moduledoc """
  Detects the locally-hosted Tidewave MCP capability.

  Tidewave is served from the Phoenix endpoint, but contexts must not depend on
  the web layer. The endpoint base URL is resolved through a configured MFA
  (`:tidewave_url_provider`), which the application wires to
  `DevIdeWeb.Endpoint.url/0`. This inverts the dependency (web -> context only),
  keeping the context out of the runtime dependency cycle while preserving
  accurate, port-aware URL resolution.

  Returns `:missing` whenever Tidewave is unavailable (e.g. any non-`:dev`
  environment, where the `:tidewave` dependency is not compiled in) or no URL
  provider is configured.
  """

  alias DevIDE.Agents.Capability

  @spec detect() :: Capability.t()
  def detect do
    case base_url() do
      url when is_binary(url) ->
        %Capability{
          kind: :tidewave,
          status: :detected,
          source: :dev_ide,
          url: url <> "/tidewave",
          details: %{mcp_url: url <> "/tidewave/mcp"}
        }

      _ ->
        %Capability{kind: :tidewave, status: :missing}
    end
  end

  defp base_url do
    with true <- Code.ensure_loaded?(Tidewave),
         {mod, fun, args} <- Application.get_env(:dev_ide, :tidewave_url_provider),
         true <- Code.ensure_loaded?(mod) do
      apply(mod, fun, args)
    else
      _ -> nil
    end
  end
end
