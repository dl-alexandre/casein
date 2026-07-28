defmodule CaseinWeb.LegacyHostRedirectTest do
  @moduledoc """
  Guards the retired-public-host redirect. See `CaseinWeb.LegacyHostRedirect`.
  """
  use ExUnit.Case, async: false

  alias CaseinWeb.LegacyHostRedirect

  @canonical "https://casein.devbox.milcgroup.com"
  @legacy "devide.devbox.milcgroup.com"

  setup do
    prev_canonical = Application.get_env(:casein, :canonical_public_origin)
    prev_deprecated = Application.get_env(:casein, :deprecated_public_hosts)

    on_exit(fn ->
      restore(:canonical_public_origin, prev_canonical)
      restore(:deprecated_public_hosts, prev_deprecated)
    end)

    Application.put_env(:casein, :canonical_public_origin, @canonical)
    Application.put_env(:casein, :deprecated_public_hosts, [@legacy])

    :ok
  end

  test "redirects a legacy-host navigation to the canonical origin" do
    conn = call(:get, @legacy, "/workspaces/abc")

    assert conn.status == 301
    assert conn.halted
    assert location(conn) == "#{@canonical}/workspaces/abc"
  end

  test "preserves the query string" do
    conn = call(:get, @legacy, "/workspaces/abc", "session=wt-123")

    assert location(conn) == "#{@canonical}/workspaces/abc?session=wt-123"
  end

  test "matches the legacy host case-insensitively" do
    conn = call(:get, String.upcase(@legacy), "/")

    assert conn.status == 301
  end

  test "passes the canonical host through untouched" do
    conn = call(:get, "casein.devbox.milcgroup.com", "/")

    refute conn.halted
    assert is_nil(conn.status)
  end

  test "passes loopback through untouched so on-box agents keep working" do
    conn = call(:get, "127.0.0.1", "/api/terminals/mcp")

    refute conn.halted
  end

  test "does not redirect non-GET requests on the legacy host" do
    conn = call(:post, @legacy, "/api/terminals/mcp")

    refute conn.halted
    assert is_nil(conn.status)
  end

  test "is inert when no canonical origin is configured" do
    Application.delete_env(:casein, :canonical_public_origin)

    conn = call(:get, @legacy, "/")

    refute conn.halted
  end

  defp call(method, host, path, query \\ "") do
    method
    |> Plug.Test.conn(path <> if(query == "", do: "", else: "?" <> query))
    |> Map.put(:host, host)
    |> LegacyHostRedirect.call(LegacyHostRedirect.init([]))
  end

  defp location(conn), do: Plug.Conn.get_resp_header(conn, "location") |> List.first()

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
