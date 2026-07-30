defmodule CaseinWeb.API.MCPProtectedResourceTest do
  @moduledoc """
  RFC 9728 discovery for the MCP endpoints.

  The whole feature is config-gated, so the most important assertions here are
  the *off* ones: an unconfigured deployment must look exactly like it did
  before.
  """

  use CaseinWeb.ConnCase, async: false

  @paths ["/api/terminals/mcp", "/api/preview/mcp", "/api/artifacts/mcp"]
  @issuer "https://idp.example.com"

  setup do
    prev_servers = Application.get_env(:casein, :mcp_authorization_servers)
    prev_scopes = Application.get_env(:casein, :mcp_scopes_supported)
    prev_origin = Application.get_env(:casein, :canonical_public_origin)
    prev_token = Application.get_env(:casein, :api_token)

    Application.put_env(:casein, :api_token, "protected-resource-token")

    on_exit(fn ->
      restore(:mcp_authorization_servers, prev_servers)
      restore(:mcp_scopes_supported, prev_scopes)
      restore(:canonical_public_origin, prev_origin)
      restore(:api_token, prev_token)
    end)

    :ok
  end

  defp enable do
    Application.put_env(:casein, :mcp_authorization_servers, [@issuer])
    Application.put_env(:casein, :canonical_public_origin, "https://casein.example.com")
  end

  defp unauthenticated(conn, path) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, %{jsonrpc: "2.0", id: 1, method: "tools/list"})
  end

  describe "when authorization is not configured (the default)" do
    test "no metadata document is published", %{conn: conn} do
      response = get(conn, "/.well-known/oauth-protected-resource/api/terminals/mcp")
      assert response.status == 404
    end

    test "401s stay byte-identical, with no challenge header", %{conn: conn} do
      for path <- @paths do
        response = unauthenticated(conn, path)

        assert response.status == 401
        assert Jason.decode!(response.resp_body) == %{"error" => "unauthorized"}
        assert get_resp_header(response, "www-authenticate") == []
      end
    end
  end

  describe "when authorization is configured" do
    setup do
      enable()
      :ok
    end

    test "each MCP endpoint publishes metadata at its RFC 9728 path", %{conn: conn} do
      for path <- @paths do
        body =
          conn
          |> recycle()
          |> get("/.well-known/oauth-protected-resource" <> path)
          |> json_response(200)

        # The resource identifier is the canonical URI a client must also send
        # as the RFC 8707 `resource` parameter.
        assert body["resource"] == "https://casein.example.com" <> path
        assert body["authorization_servers"] == [@issuer]
        assert body["bearer_methods_supported"] == ["header"]
        assert body["scopes_supported"] == ["casein:mcp"]
      end
    end

    test "a 401 points at the metadata for that exact endpoint", %{conn: conn} do
      for path <- @paths do
        response = unauthenticated(conn, path)

        assert response.status == 401
        assert [challenge] = get_resp_header(response, "www-authenticate")

        assert challenge =~
                 ~s(resource_metadata="https://casein.example.com/.well-known/oauth-protected-resource#{path}")

        assert challenge =~ ~s(scope="casein:mcp")

        # The body is unchanged — the header is purely additive.
        assert Jason.decode!(response.resp_body) == %{"error" => "unauthorized"}
      end
    end

    test "a valid bearer token still works and gets no challenge", %{conn: conn} do
      response =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer protected-resource-token")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> post("/api/terminals/mcp", %{jsonrpc: "2.0", id: 1, method: "tools/list"})

      assert response.status == 200
      assert get_resp_header(response, "www-authenticate") == []
    end

    test "non-MCP API 401s are not given a challenge", %{conn: conn} do
      # ApiAuth fronts the whole read-only API; only the MCP endpoints opt in.
      response =
        conn
        |> recycle()
        |> put_req_header("accept", "application/json")
        |> get("/api/workspaces")

      assert response.status == 401
      assert get_resp_header(response, "www-authenticate") == []
    end

    test "metadata is not published for paths that are not MCP endpoints", %{conn: conn} do
      assert get(conn, "/.well-known/oauth-protected-resource/api/workspaces").status == 404
    end

    test "offline_access is never advertised as a resource scope" do
      refute "offline_access" in CaseinWeb.API.MCPProtectedResource.scopes_supported()
    end
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
