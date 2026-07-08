defmodule DevIdeWeb.Plugs.ForwardAuthRouterSafetyTest do
  @moduledoc """
  Regression guard for the Caddy forward-auth bypass matchers (OPTIONS,
  /site.webmanifest). See `DevIdeWeb.Plugs.ForwardAuth` moduledoc.
  """
  use DevIdeWeb.ConnCase, async: false

  alias DevIdeWeb.Plugs.ForwardAuth

  setup %{conn: conn} = context do
    prev = Application.get_env(:dev_ide, :forward_auth)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:dev_ide, :forward_auth)
        val -> Application.put_env(:dev_ide, :forward_auth, val)
      end
    end)

    Application.put_env(:dev_ide, :forward_auth, true)
    Map.put(context, :conn, conn)
  end

  test "OPTIONS to an unmatched path returns 404 without assigning identity", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-auth-request-email", "attacker@evil.com")
      |> options("/")

    assert conn.status == 404
    refute Map.has_key?(conn.assigns, :current_user)
  end

  test "router declares no explicit :options routes outside preview-proxy catch-all" do
    explicit_options =
      DevIdeWeb.Router.__routes__()
      |> Enum.filter(&(&1.verb == :options))

    assert explicit_options == []
  end

  test "preview-proxy catch-all is the only route that accepts arbitrary verbs" do
    catch_all =
      DevIdeWeb.Router.__routes__()
      |> Enum.filter(&(&1.verb == :*))

    assert length(catch_all) == 1
    assert hd(catch_all).path == "/preview-proxy/:workspace_id/:port/*path"
  end

  test "GET still requires forward-auth identity on browser routes", %{conn: conn} do
    conn = get(conn, "/")

    assert conn.status == 401
    refute Map.has_key?(conn.assigns, :current_user)
  end

  test "GET with a trusted header assigns identity on browser routes", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-auth-request-email", "dev@local")
      |> get("/")

    refute conn.status == 401
    assert conn.assigns.current_user.email == "dev@local"
    assert ForwardAuth.enabled?()
  end
end
