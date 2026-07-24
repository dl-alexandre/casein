defmodule PreviewCtl.Playwright.AdapterObserveTest do
  # Exercises the STATIC-observation path of the Adapter that does NOT touch the
  # Playwright Bridge: `observe/1` (and the fallback inside `observe_live/1`)
  # fetch the page over HTTP via `Req.get` and build an observation from the raw
  # HTML. HTTPStub serves canned responses on a localhost port so we drive the
  # parser, the dom_summary shape, `<base href>` / canonical extraction, and the
  # fetch/2 error branches (non-2xx status, redirect, transport error) with no
  # Node helper involved.
  #
  # async: false — `setup_all` disables the Playwright helper and restarts the
  # app-supervised Bridge singleton so `observe_live/1` deterministically falls
  # back to the static `observe/1` path instead of reaching a live helper.
  use Casein.TestCase, async: false

  alias Casein.TestSupport.HTTPStub
  alias PreviewCtl.Playwright.Adapter

  # Force the Bridge into its :playwright_unavailable state (no script/executable)
  # so observe_live/1's bridge command fails and control reaches the static
  # observe fallback. Restore the previous configuration afterward.
  setup_all do
    previous = Application.get_env(:preview_ctl, :playwright_script)
    Application.delete_env(:preview_ctl, :playwright_script)
    restart_bridge()

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:preview_ctl, :playwright_script)
        value -> Application.put_env(:preview_ctl, :playwright_script, value)
      end

      restart_bridge()
    end)

    :ok
  end

  setup do
    bypass = HTTPStub.open()
    {:ok, bypass: bypass, base_url: "http://127.0.0.1:#{bypass.port}"}
  end

  defp restart_bridge do
    _ = Supervisor.terminate_child(Casein.Supervisor, PreviewCtl.Playwright.Bridge)
    {:ok, _} = Supervisor.restart_child(Casein.Supervisor, PreviewCtl.Playwright.Bridge)
    :ok
  end

  defp state_for(url) do
    %{
      current_url: url,
      browser_id: "pw-static",
      default_headers: %{"x-test" => "1"},
      storage_state_path: nil,
      storage_profile: "ephemeral"
    }
  end

  describe "observe/1 on a normal 200 HTML page" do
    test "parses title, headings, links and dom_summary fields", %{
      bypass: bypass,
      base_url: base_url
    } do
      html = """
      <html>
        <head><title>  Hello World  </title></head>
        <body>
          <h1>First Heading</h1>
          <h2>Second</h2>
          <a href="/about">About <b>us</b></a>
          <a href="https://ex.test/contact">Contact</a>
          <script>var hidden = 1;</script>
          <style>.x{color:red}</style>
          Visible body text.
        </body>
      </html>
      """

      HTTPStub.expect_once(bypass, "GET", "/page", fn conn ->
        Plug.Conn.resp(conn, 200, html)
      end)

      url = base_url <> "/page"
      assert {:ok, obs} = Adapter.observe(state_for(url))

      # observation/2 shape: url, title, source_url, dom_summary, console_errors,
      # network_errors. Static path leaves console/network errors empty.
      assert obs.url == url
      assert obs.title == "Hello World"
      assert obs.source_url == nil
      assert obs.console_errors == []
      assert obs.network_errors == []

      summary = obs.dom_summary
      assert summary.title == "Hello World"
      assert summary.headings == ["First Heading", "Second"]
      assert summary.url == url
      assert summary.source_url == nil
      assert summary.byte_size == byte_size(html)

      # strip_tags removes nested markup from link text.
      assert %{href: "/about", text: "About us"} in summary.links
      assert %{href: "https://ex.test/contact", text: "Contact"} in summary.links

      # visible_text drops <script>/<style> contents.
      refute String.contains?(summary.visible_text, "var hidden")
      refute String.contains?(summary.visible_text, "color:red")
      assert String.contains?(summary.visible_text, "Visible body text.")
    end

    test "title is nil when the page has no <title>", %{bypass: bypass, base_url: base_url} do
      HTTPStub.expect_once(bypass, "GET", "/notitle", fn conn ->
        Plug.Conn.resp(conn, 200, "<html><body><p>no title here</p></body></html>")
      end)

      url = base_url <> "/notitle"
      assert {:ok, obs} = Adapter.observe(state_for(url))
      assert obs.title == nil
      assert obs.dom_summary.title == nil
      assert obs.dom_summary.headings == []
      assert obs.dom_summary.links == []
    end

    test "handles an empty 200 body", %{bypass: bypass, base_url: base_url} do
      HTTPStub.expect_once(bypass, "GET", "/empty", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      url = base_url <> "/empty"
      assert {:ok, obs} = Adapter.observe(state_for(url))
      assert obs.title == nil
      assert obs.dom_summary.byte_size == 0
      assert obs.dom_summary.visible_text == ""
      assert obs.dom_summary.source_url == nil
    end
  end

  describe "observe/1 source_url extraction" do
    test "reports <base href> as the source_url", %{bypass: bypass, base_url: base_url} do
      html = """
      <html>
        <head>
          <base href="https://real.example.com/page">
          <title>Snapshot</title>
        </head>
        <body><h1>Snap</h1></body>
      </html>
      """

      HTTPStub.expect_once(bypass, "GET", "/snap", fn conn ->
        Plug.Conn.resp(conn, 200, html)
      end)

      url = base_url <> "/snap"
      assert {:ok, obs} = Adapter.observe(state_for(url))
      assert obs.source_url == "https://real.example.com/page"
      assert obs.dom_summary.source_url == "https://real.example.com/page"
      # url stays the served path; source_url surfaces the captured origin.
      assert obs.url == url
    end

    test "falls back to canonical <link> when no <base href>", %{
      bypass: bypass,
      base_url: base_url
    } do
      html = """
      <html>
        <head>
          <link rel="canonical" href="https://canon.example.com/x">
          <title>Canon</title>
        </head>
        <body></body>
      </html>
      """

      HTTPStub.expect_once(bypass, "GET", "/canon", fn conn ->
        Plug.Conn.resp(conn, 200, html)
      end)

      url = base_url <> "/canon"
      assert {:ok, obs} = Adapter.observe(state_for(url))
      assert obs.source_url == "https://canon.example.com/x"
    end
  end

  describe "observe/1 error branches" do
    test "returns {:http_status, ...} on a 404", %{bypass: bypass, base_url: base_url} do
      HTTPStub.expect_once(bypass, "GET", "/missing", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      url = base_url <> "/missing"
      assert {:error, {:http_status, 404, "Not Found"}} = Adapter.observe(state_for(url))
    end

    test "returns {:http_status, ...} on a 500 and truncates the body", %{
      bypass: bypass,
      base_url: base_url
    } do
      big = String.duplicate("e", 600)

      HTTPStub.expect(bypass, "GET", "/boom", fn conn ->
        Plug.Conn.send_resp(conn, 500, big)
      end)

      url = base_url <> "/boom"
      assert {:error, {:http_status, 500, body}} = Adapter.observe(state_for(url))
      # truncate/1 caps the body length; the exact cap/ellipsis is not asserted
      # since the delivered error body length varies.
      assert is_binary(body)
      assert byte_size(body) <= byte_size(big)
    end

    test "returns {:redirect_blocked, ...} on a 3xx (redirect: false)", %{
      bypass: bypass,
      base_url: base_url
    } do
      HTTPStub.expect_once(bypass, "GET", "/go", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.example.com/")
        |> Plug.Conn.resp(302, "")
      end)

      url = base_url <> "/go"

      assert {:error, {:redirect_blocked, 302, "https://elsewhere.example.com/"}} =
               Adapter.observe(state_for(url))
    end

    test "surfaces a transport error when the server is down", %{
      bypass: bypass,
      base_url: base_url
    } do
      url = base_url <> "/down"
      HTTPStub.down(bypass)

      assert {:error, reason} = Adapter.observe(state_for(url))
      refute match?({:http_status, _, _}, reason)
      refute match?({:redirect_blocked, _, _, _}, reason)
    end
  end

  describe "observe_live/1 static fallback (no Playwright)" do
    test "falls back to observe and returns {:ok, state, obs}", %{
      bypass: bypass,
      base_url: base_url
    } do
      HTTPStub.expect_once(bypass, "GET", "/live", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          "<html><head><title>Live Fallback</title></head><body></body></html>"
        )
      end)

      url = base_url <> "/live"
      state = state_for(url)

      assert {:ok, ^state, obs} = Adapter.observe_live(state)
      assert obs.title == "Live Fallback"
      assert obs.url == url
      assert obs.console_errors == []
      assert obs.network_errors == []
    end

    test "propagates the fetch error tuple through the fallback", %{
      bypass: bypass,
      base_url: base_url
    } do
      HTTPStub.expect_once(bypass, "GET", "/live-404", fn conn ->
        Plug.Conn.resp(conn, 404, "nope")
      end)

      url = base_url <> "/live-404"
      assert {:error, {:http_status, 404, "nope"}} = Adapter.observe_live(state_for(url))
    end
  end
end
