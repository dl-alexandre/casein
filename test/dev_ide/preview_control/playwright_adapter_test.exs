defmodule DevIDE.PreviewControl.PlaywrightAdapterTest do
  use ExUnit.Case, async: true

  alias DevIDE.PreviewControl.PlaywrightAdapter

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, url: "http://localhost:#{bypass.port}"}
  end

  test "observe summarizes a 2xx html page", %{bypass: bypass, url: url} do
    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        "<html><head><title>Hello</title></head><body><h1>Hi</h1></body></html>"
      )
    end)

    assert {:ok, observation} = PlaywrightAdapter.observe(%{current_url: url})
    assert observation.title == "Hello"
    assert observation.url == url
  end

  test "does not follow redirects to other hosts (SSRF guard)", %{bypass: bypass, url: url} do
    # A trusted preview URL that 302s to an internal/metadata host must NOT be
    # followed — fetch returns an error instead of summarizing the redirect target.
    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
      |> Plug.Conn.resp(302, "")
    end)

    assert {:error, {:redirect_blocked, 302, location}} =
             PlaywrightAdapter.observe(%{current_url: url})

    assert location == "http://169.254.169.254/latest/meta-data/"
  end

  test "navigate also refuses to follow redirects", %{bypass: bypass, url: url} do
    Bypass.expect_once(bypass, "GET", "/next", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://evil.example/")
      |> Plug.Conn.resp(301, "")
    end)

    assert {:error, {:redirect_blocked, 301, _}} =
             PlaywrightAdapter.navigate(%{current_url: url, browser_id: "pw-test"}, "#{url}/next")
  end
end
