defmodule CaseinWeb.API.MCPProtectedResource do
  @moduledoc """
  OAuth 2.0 Protected Resource Metadata (RFC 9728) for Casein's MCP endpoints.

  Authorization is optional in MCP, but a server that offers it **MUST** publish
  this document and point at it from the `WWW-Authenticate` challenge on a 401.
  That pair is the whole discovery story: an MCP client with no credentials gets
  a 401, reads `resource_metadata` from the challenge, fetches this document, and
  learns which authorization server to talk to.

  Casein has no authorization server of its own — the box already sits behind
  oauth2-proxy, whose upstream IdP is the AS. So this module is **config-gated**:

    * `:mcp_authorization_servers` — issuer URLs. Empty (the default) means
      authorization is not offered, and we publish nothing rather than advertise
      a document that points nowhere.
    * `:mcp_scopes_supported` — the minimal scope set for basic functionality.

  Nothing here changes how requests are authenticated. `CaseinWeb.Plugs.ApiAuth`
  still gates every MCP request on a bearer token exactly as before; this only
  makes an unauthenticated caller's 401 *self-describing*. Wiring token
  verification to an IdP is a separate change with a much larger blast radius —
  `ApiAuth` fronts the entire read-only API, not just MCP.
  """

  @well_known "/.well-known/oauth-protected-resource"

  @mcp_paths ["/api/terminals/mcp", "/api/preview/mcp", "/api/artifacts/mcp"]

  @doc "The MCP endpoint paths this metadata describes."
  @spec mcp_paths() :: [String.t()]
  def mcp_paths, do: @mcp_paths

  @doc "Whether the request path is one of the MCP endpoints."
  @spec mcp_path?(String.t()) :: boolean()
  def mcp_path?(path), do: path in @mcp_paths

  @doc """
  Whether authorization discovery is configured.

  False by default: an unconfigured deployment keeps the plain bearer behaviour
  and advertises no OAuth affordance at all.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: authorization_servers() != []

  @doc "Configured authorization server issuer URLs."
  @spec authorization_servers() :: [String.t()]
  def authorization_servers do
    :casein
    |> Application.get_env(:mcp_authorization_servers, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  @doc "The minimal scope set needed for basic MCP functionality."
  @spec scopes_supported() :: [String.t()]
  def scopes_supported do
    # `offline_access` deliberately absent — refresh tokens are a client
    # concern, not a resource requirement.
    Application.get_env(:casein, :mcp_scopes_supported, ["casein:mcp"])
  end

  @doc """
  The RFC 9728 metadata document for one MCP endpoint.

  `resource` is the canonical URI of that endpoint, which is also what a client
  must send as the RFC 8707 `resource` parameter when requesting a token.
  """
  @spec metadata(String.t(), String.t()) :: map()
  def metadata(origin, resource_path) do
    %{
      resource: resource_identifier(origin, resource_path),
      authorization_servers: authorization_servers(),
      bearer_methods_supported: ["header"],
      scopes_supported: scopes_supported(),
      resource_name: "Casein MCP",
      resource_documentation: origin <> "/docs/reference/mcp_tools.md"
    }
  end

  @doc "Canonical URI of an MCP endpoint — no trailing slash, no fragment."
  @spec resource_identifier(String.t(), String.t()) :: String.t()
  def resource_identifier(origin, resource_path), do: origin <> resource_path

  @doc "URL of the metadata document describing `resource_path`."
  @spec metadata_url(String.t(), String.t()) :: String.t()
  def metadata_url(origin, resource_path), do: origin <> @well_known <> resource_path

  @doc """
  The `WWW-Authenticate` challenge for an unauthenticated MCP request.

  Returns nil when authorization is not configured, so an unconfigured
  deployment's 401 stays byte-identical to what it was.
  """
  @spec challenge(String.t(), String.t()) :: String.t() | nil
  def challenge(origin, resource_path) do
    if enabled?() do
      scopes = Enum.join(scopes_supported(), " ")

      ~s(Bearer resource_metadata="#{metadata_url(origin, resource_path)}", scope="#{scopes}")
    end
  end

  @doc "The well-known prefix these documents are served under."
  @spec well_known_prefix() :: String.t()
  def well_known_prefix, do: @well_known
end
