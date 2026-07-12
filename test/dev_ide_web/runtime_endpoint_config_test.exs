defmodule DevIdeWeb.RuntimeEndpointConfigTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias DevIdeWeb.RuntimeSSLPlug
  alias DevIdeWeb.RuntimeSessionPlug
  alias DevIdeWeb.OriginOptions
  alias DevIdeWeb.SessionOptions

  @env_keys [
    :lan_insecure_http,
    :runtime_force_ssl,
    :runtime_force_ssl_options,
    :secure_session_cookie,
    :session_cookie_key,
    :session_same_site
  ]

  setup do
    saved =
      Map.new(@env_keys, fn key ->
        {key, Application.fetch_env(:dev_ide, key)}
      end)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:dev_ide, key, value)
        {key, :error} -> Application.delete_env(:dev_ide, key)
      end)
    end)
  end

  test "session options use runtime LAN cookie config" do
    Application.put_env(:dev_ide, :session_cookie_key, "_dev_ide_lan_http_key")
    Application.put_env(:dev_ide, :secure_session_cookie, true)
    Application.put_env(:dev_ide, :lan_insecure_http, true)
    Application.put_env(:dev_ide, :session_same_site, nil)

    opts = SessionOptions.options()

    assert opts[:key] == "_dev_ide_lan_http_key"
    assert opts[:secure] == false
    refute Keyword.has_key?(opts, :same_site)
  end

  test "session options keep secure cookies outside insecure LAN HTTP" do
    Application.put_env(:dev_ide, :secure_session_cookie, true)
    Application.delete_env(:dev_ide, :lan_insecure_http)

    opts = SessionOptions.options()

    assert opts[:secure] == true
  end

  test "runtime session plug writes the current cookie key" do
    Application.put_env(:dev_ide, :session_cookie_key, "_dev_ide_lan_http_key")
    Application.put_env(:dev_ide, :session_same_site, nil)

    conn =
      :get
      |> conn("/")
      |> Map.put(:secret_key_base, String.duplicate("a", 64))
      |> RuntimeSessionPlug.call([])
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_session(:marker, "ok")
      |> Plug.Conn.send_resp(200, "ok")

    [cookie] = Plug.Conn.get_resp_header(conn, "set-cookie")

    assert cookie =~ "_dev_ide_lan_http_key="
    refute cookie =~ "SameSite"
  end

  test "runtime SSL plug redirects when enabled" do
    Application.put_env(:dev_ide, :runtime_force_ssl, true)
    Application.delete_env(:dev_ide, :lan_insecure_http)

    conn = RuntimeSSLPlug.call(conn(:get, "http://example.com/workspaces"), [])

    assert conn.halted
    assert Plug.Conn.get_resp_header(conn, "location") == ["https://example.com/workspaces"]
  end

  test "endpoint pipeline enforces runtime SSL before app routing" do
    Application.put_env(:dev_ide, :runtime_force_ssl, true)
    Application.delete_env(:dev_ide, :lan_insecure_http)

    conn = DevIdeWeb.Endpoint.call(conn(:get, "http://example.com/workspaces"), [])

    assert conn.halted
    assert Plug.Conn.get_resp_header(conn, "location") == ["https://example.com/workspaces"]
  end

  test "runtime SSL permits plain HTTP readiness probes on non-loopback hosts" do
    Application.put_env(:dev_ide, :runtime_force_ssl, true)
    Application.delete_env(:dev_ide, :lan_insecure_http)

    conn = RuntimeSSLPlug.call(conn(:get, "http://10.0.0.8/healthz"), [])

    refute conn.halted
    assert Plug.Conn.get_resp_header(conn, "location") == []
  end

  test "runtime SSL plug stays off for insecure LAN HTTP" do
    Application.put_env(:dev_ide, :runtime_force_ssl, true)
    Application.put_env(:dev_ide, :lan_insecure_http, true)

    conn = RuntimeSSLPlug.call(conn(:get, "http://r630.local/"), [])

    refute conn.halted
    assert Plug.Conn.get_resp_header(conn, "location") == []
  end

  test "LAN origin checks allow only configured LAN hosts and loopback" do
    assert OriginOptions.lan("r630.local", scheme: "http", port: 80, lan_ip: "192.168.1.240") ==
             [
               "http://r630.local",
               "http://192.168.1.240",
               "http://localhost",
               "http://127.0.0.1"
             ]
  end

  test "LAN origin checks include non-default ports" do
    assert "http://r630.local:8080" in OriginOptions.lan("r630.local",
             scheme: "http",
             port: 8080
           )
  end
end
