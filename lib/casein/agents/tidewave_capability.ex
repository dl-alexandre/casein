defmodule Casein.Agents.TidewaveCapability do
  @moduledoc """
  Detects the locally-hosted Tidewave MCP capability.

  Tidewave is served from the Phoenix endpoint, but contexts must not depend on
  the web layer. The endpoint base URL is resolved through a configured MFA
  (`:tidewave_url_provider`), which the application wires to
  `CaseinWeb.Endpoint.url/0`. This inverts the dependency (web -> context only),
  keeping the context out of the runtime dependency cycle while preserving
  accurate, port-aware URL resolution.

  Returns `:missing` whenever Tidewave is unavailable (e.g. any non-`:dev`
  environment, where the `:tidewave` dependency is not compiled in) or no URL
  provider is configured.

  Ephemeral preview environments (`scripts/preview-env.sh`, ports 41000–41049)
  boot `MIX_ENV=dev` and therefore expose Tidewave on the allocated loopback
  port. Those instances tag `source: :preview_env` in the capability record.
  """

  alias Casein.Agents.Capability
  alias Casein.Previews.EnvPorts

  @spec detect() :: Capability.t()
  def detect do
    case base_url() do
      url when is_binary(url) ->
        port = EnvPorts.current_port()
        preview? = EnvPorts.preview_env_instance?()

        %Capability{
          kind: :tidewave,
          status: :detected,
          source: if(preview?, do: :preview_env, else: :casein),
          url: url <> "/tidewave",
          details: %{
            mcp_url: url <> "/tidewave/mcp",
            port: port,
            preview_env: preview?
          }
        }

      _ ->
        %Capability{kind: :tidewave, status: :missing}
    end
  end

  defp base_url do
    with true <- Code.ensure_loaded?(Tidewave),
         {mod, fun, args} <- Application.get_env(:casein, :tidewave_url_provider),
         true <- Code.ensure_loaded?(mod) do
      apply(mod, fun, args)
    else
      _ -> nil
    end
  end
end
