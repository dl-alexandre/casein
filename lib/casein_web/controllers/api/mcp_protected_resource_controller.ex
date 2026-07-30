defmodule CaseinWeb.API.MCPProtectedResourceController do
  @moduledoc """
  Serves the RFC 9728 Protected Resource Metadata documents.

  Deliberately unauthenticated: a client fetches this *because* it does not yet
  have a token, so requiring one would make discovery impossible. The document
  contains no secrets — issuer URLs, scope names, and the endpoint's own URI.

  404s when authorization is not configured, so an unconfigured deployment
  exposes no new surface at all.
  """

  use CaseinWeb, :controller

  alias CaseinWeb.API.MCPProtectedResource

  @doc """
  `GET /.well-known/oauth-protected-resource/*resource`

  RFC 9728 locates the document by inserting the well-known segment before the
  resource's own path, so `/api/terminals/mcp` is described at
  `/.well-known/oauth-protected-resource/api/terminals/mcp`.
  """
  def show(conn, params) do
    resource_path = "/" <> Enum.join(Map.get(params, "resource", []), "/")

    cond do
      not MCPProtectedResource.enabled?() ->
        not_found(conn)

      not MCPProtectedResource.mcp_path?(resource_path) ->
        not_found(conn)

      true ->
        conn
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> json(MCPProtectedResource.metadata(origin(conn), resource_path))
    end
  end

  defp not_found(conn) do
    conn |> put_status(404) |> json(%{error: "protected_resource_metadata_not_found"})
  end

  # Prefer the deployment's canonical public origin: the metadata `resource`
  # value must match the URI clients actually use, not whatever Host header
  # reached us behind the proxy.
  defp origin(conn) do
    case Application.get_env(:casein, :canonical_public_origin) do
      origin when is_binary(origin) and origin != "" -> String.trim_trailing(origin, "/")
      _ -> "#{conn.scheme}://#{conn.host}#{port_suffix(conn)}"
    end
  end

  defp port_suffix(%{scheme: :https, port: 443}), do: ""
  defp port_suffix(%{scheme: :http, port: 80}), do: ""
  defp port_suffix(%{port: port}), do: ":#{port}"
end
