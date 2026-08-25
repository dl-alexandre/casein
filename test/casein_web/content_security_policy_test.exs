defmodule CaseinWeb.ContentSecurityPolicyTest do
  use CaseinWeb.ConnCase, async: false

  @root_layout "lib/casein_web/components/layouts/root.html.heex"

  test "CSP header is present on browser routes", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "object-src 'none'"
    assert csp =~ "frame-ancestors 'self'"
  end

  test "CSP permits configured internal superadmin embedding", %{conn: conn} do
    original = Application.get_env(:casein, :embed_origins)

    on_exit(fn ->
      if original do
        Application.put_env(:casein, :embed_origins, original)
      else
        Application.delete_env(:casein, :embed_origins)
      end
    end)

    Application.put_env(:casein, :embed_origins, ["https://dev.milcgroup.com"])

    conn = get(conn, ~p"/")
    [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "frame-ancestors 'self' https://dev.milcgroup.com"
  end

  test "script-src hash matches the inline theme script in the root layout", %{conn: conn} do
    conn = get(conn, ~p"/")
    [csp] = get_resp_header(conn, "content-security-policy")

    if csp =~ "sha256-" do
      # Strict (non-dev_routes) build: the hash in the header must match the
      # actual bytes of the inline theme script. If this fails, you edited
      # the theme script in root.html.heex — recompute the hash (command in
      # the router comment) and update @theme_script_hash.
      [_, script] =
        Regex.run(~r/<script>(.*?)<\/script>/s, File.read!(@root_layout))

      expected = "sha256-" <> Base.encode64(:crypto.hash(:sha256, script))

      assert csp =~ expected,
             "CSP script hash out of date: expected #{expected} in #{csp}"
    else
      # dev_routes build falls back to 'unsafe-inline' for LiveDashboard.
      assert csp =~ "'unsafe-inline'"
    end
  end
end
