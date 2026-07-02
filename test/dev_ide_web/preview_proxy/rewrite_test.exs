defmodule DevIdeWeb.PreviewProxy.RewriteTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.PreviewProxy.Rewrite

  describe "droppable_header?/1" do
    test "drops frame blockers regardless of case" do
      assert Rewrite.droppable_header?("X-Frame-Options")
      assert Rewrite.droppable_header?("content-security-policy")
      assert Rewrite.droppable_header?("Content-Security-Policy-Report-Only")
      assert Rewrite.droppable_header?("strict-transport-security")
    end

    test "drops cross-origin isolation headers that block sandboxed proxied assets" do
      assert Rewrite.droppable_header?("Cross-Origin-Resource-Policy")
      assert Rewrite.droppable_header?("cross-origin-embedder-policy")
      assert Rewrite.droppable_header?("Cross-Origin-Opener-Policy")
    end

    test "drops framing/length headers that no longer match the re-served body" do
      for h <- ~w(content-length content-encoding transfer-encoding connection) do
        assert Rewrite.droppable_header?(h)
      end
    end

    test "keeps ordinary content headers" do
      refute Rewrite.droppable_header?("content-type")
      refute Rewrite.droppable_header?("cache-control")
      refute Rewrite.droppable_header?("etag")
    end
  end

  describe "forward_headers/1" do
    test "strips blockers and downcases names (list shape)" do
      headers = [
        {"Content-Type", "text/html"},
        {"X-Frame-Options", "DENY"},
        {"Content-Security-Policy", "frame-ancestors 'none'"},
        {"Cross-Origin-Resource-Policy", "same-origin"},
        {"Cache-Control", "no-store"},
        {"Content-Length", "1234"}
      ]

      out = Rewrite.forward_headers(headers)

      assert {"content-type", "text/html"} in out
      assert {"cache-control", "no-store"} in out

      refute Enum.any?(out, fn {k, _} ->
               k in ~w(
                 x-frame-options content-security-policy cross-origin-resource-policy
                 content-length
               )
             end)
    end

    test "handles Req's map shape with list values" do
      headers = %{
        "content-type" => ["application/json"],
        "set-cookie" => ["sid=one; Path=/", "theme=dark; Path=/"],
        "x-frame-options" => ["SAMEORIGIN"]
      }

      out = Rewrite.forward_headers(headers)

      assert {"content-type", "application/json"} in out
      assert {"set-cookie", "sid=one; Path=/"} in out
      assert {"set-cookie", "theme=dark; Path=/"} in out
      refute Enum.any?(out, fn {k, _} -> k == "x-frame-options" end)
    end
  end

  describe "html?/1" do
    test "matches html content types" do
      assert Rewrite.html?("text/html")
      assert Rewrite.html?("text/html; charset=utf-8")
      refute Rewrite.html?("application/json")
      refute Rewrite.html?(nil)
    end
  end

  describe "css?/1" do
    test "matches css content types" do
      assert Rewrite.css?("text/css")
      assert Rewrite.css?("text/css; charset=utf-8")
      refute Rewrite.css?("text/html")
      refute Rewrite.css?(nil)
    end
  end

  describe "javascript?/1" do
    test "matches javascript content types" do
      assert Rewrite.javascript?("application/javascript")
      assert Rewrite.javascript?("text/javascript; charset=utf-8")
      refute Rewrite.javascript?("text/css")
      refute Rewrite.javascript?(nil)
    end
  end

  describe "inject_base/2" do
    test "inserts <base> right after <head>" do
      html = "<html><head><title>x</title></head><body>hi</body></html>"
      out = Rewrite.inject_base(html, "/preview-proxy/ws/3000/")

      assert out =~ ~s(<head><base href="/preview-proxy/ws/3000/"><script>)
      assert out =~ ~s(</script>\n<title>)
    end

    test "injects a storage shim before page scripts for sandboxed proxied apps" do
      html = ~s(<html><head><script src="/assets/app.js"></script></head></html>)
      out = Rewrite.inject_base(html, "/preview-proxy/ws/3000/")

      assert out =~ "install(\"localStorage\")"
      assert out =~ "install(\"sessionStorage\")"
      assert out =~ ~s(Object.defineProperty(document, "cookie")

      assert String.split(out, ~s(<script src="/preview-proxy/ws/3000/assets/app.js">)) |> hd() =~
               "install(\"localStorage\")"
    end

    test "is a no-op when a <base> already exists" do
      html = ~s(<html><head><base href="/x/"></head></html>)
      assert Rewrite.inject_base(html, "/preview-proxy/ws/3000/") == html
    end

    test "is a no-op when there is no <head>" do
      html = "<html><body>no head here</body></html>"
      assert Rewrite.inject_base(html, "/preview-proxy/ws/3000/") == html
    end

    test "matches <head> with attributes, case-insensitively, only once" do
      html = ~s(<HEAD lang="en"></HEAD><head></head>)
      out = Rewrite.inject_base(html, "/b/")

      assert out =~ ~s(<HEAD lang="en"><base href="/b/">)
      # only the first head gets a base
      assert out |> String.split(~s(<base href="/b/">)) |> length() == 2
    end

    test "rewrites root-relative asset and navigation attributes" do
      html =
        ~s(<head><link href="/assets/app.css"><script src="/assets/app.js"></script></head><body><form action="/login"><a href="/dashboard">Go</a><a href="#local">Local</a><img src="//cdn.example/x.png"></body>)

      out = Rewrite.inject_base(html, "/preview-proxy/ws/41330/")

      assert out =~ ~s(href="/preview-proxy/ws/41330/assets/app.css")
      assert out =~ ~s(src="/preview-proxy/ws/41330/assets/app.js")
      assert out =~ ~s(action="/preview-proxy/ws/41330/login")
      assert out =~ ~s(href="/preview-proxy/ws/41330/dashboard")
      assert out =~ ~s(href="#local")
      assert out =~ ~s(src="//cdn.example/x.png")
    end

    test "does not double-rewrite existing proxy paths" do
      html =
        ~s(<link href="/preview-proxy/ws/41330/assets/app.css"><img src="/preview-artifacts/ws/1.png">)

      assert Rewrite.inject_base(html, "/preview-proxy/ws/41330/") =~
               ~s(href="/preview-proxy/ws/41330/assets/app.css")
    end
  end

  describe "rewrite_css_urls/2" do
    test "rewrites root-relative url references" do
      css = """
      .a{background:url("/images/bg.png")}
      .b{mask:url('/icons/x.svg')}
      .c{src:url(/fonts/app.woff2)}
      .d{background:url(https://cdn/x.png)}
      """

      out = Rewrite.rewrite_css_urls(css, "/preview-proxy/ws/41330/")

      assert out =~ "url(\"/preview-proxy/ws/41330/images/bg.png\")"
      assert out =~ "url('/preview-proxy/ws/41330/icons/x.svg')"
      assert out =~ "url(/preview-proxy/ws/41330/fonts/app.woff2)"
      assert out =~ "url(https://cdn/x.png)"
    end
  end

  describe "rewrite_phoenix_socket_paths/2" do
    test "rewrites standard Phoenix socket endpoint literals" do
      js =
        ~s|new LiveSocket("/live",Socket,{});new Socket('/socket');"/api";"/phoenix/live_reload/socket"|

      out = Rewrite.rewrite_phoenix_socket_paths(js, "/preview-proxy/ws/41330/")

      assert out =~ ~s|new LiveSocket("/preview-proxy/ws/41330/live",Socket,{})|
      assert out =~ ~s|new Socket('/preview-proxy/ws/41330/socket')|
      assert out =~ ~s|"/preview-proxy/ws/41330/phoenix/live_reload/socket"|
      assert out =~ ~s|"/api"|
    end

    test "preserves query strings" do
      js = ~s|new LiveSocket("/live?vsn=2.0.0",Socket,{})|

      assert Rewrite.rewrite_phoenix_socket_paths(js, "/preview-proxy/ws/41330/") =~
               ~s|"/preview-proxy/ws/41330/live?vsn=2.0.0"|
    end

    test "does not rewrite unrelated strings that merely contain socket names" do
      js = ~s|const api="/api/live";const text="connect to /socket later";|

      assert Rewrite.rewrite_phoenix_socket_paths(js, "/preview-proxy/ws/41330/") == js
    end
  end

  describe "first_header/2" do
    test "reads list and map shapes" do
      assert Rewrite.first_header([{"Content-Type", "text/css"}], "content-type") == "text/css"
      assert Rewrite.first_header(%{"content-type" => ["text/css"]}, "content-type") == "text/css"
      assert Rewrite.first_header([], "content-type") == nil
    end
  end

  describe "inject_hmr_assets/2" do
    test "injects an import map remapping root-absolute specifiers through the prefix" do
      html = "<html><head><title>x</title></head><body></body></html>"
      out = Rewrite.inject_hmr_assets(html, "/preview-proxy/ws/5173/")

      assert out =~
               ~s(<script type="importmap">{"imports":{"/":"/preview-proxy/ws/5173/"}}</script>)

      # import map lands before the existing <head> content so it precedes scripts
      assert out =~ ~r/<head>\s*<script type="importmap"/
    end

    test "injects a WebSocket reroute shim" do
      html = "<html><head></head><body></body></html>"
      out = Rewrite.inject_hmr_assets(html, "/preview-proxy/ws/5173/")

      assert out =~ "window.WebSocket = Patched"
      assert out =~ ~s(const PREFIX = "/preview-proxy/ws/5173/")
    end

    test "skips the import map when the document already ships one, keeping the shim" do
      html = ~s(<html><head><script type="importmap">{}</script></head><body></body></html>)
      out = Rewrite.inject_hmr_assets(html, "/preview-proxy/ws/5173/")

      # our remap is not added (only the app's own import map remains)
      refute out =~ ~s({"imports":{"/":"/preview-proxy/ws/5173/"}})
      assert out =~ "window.WebSocket = Patched"
    end

    test "normalizes a prefix without a trailing slash" do
      html = "<html><head></head><body></body></html>"
      out = Rewrite.inject_hmr_assets(html, "/preview-proxy/ws/5173")

      assert out =~ ~s({"imports":{"/":"/preview-proxy/ws/5173/"}})
    end

    test "is a no-op when there is no <head>" do
      html = "<html><body>no head</body></html>"
      assert Rewrite.inject_hmr_assets(html, "/preview-proxy/ws/5173/") == html
    end

    test "the shim carries the workspace id for absolute loopback ws reroutes" do
      html = "<html><head></head><body></body></html>"
      out = Rewrite.inject_hmr_assets(html, "/preview-proxy/ws-42/5173/")

      assert out =~ ~s(const WSID = "ws-42")
    end
  end

  describe "rewrite_loopback_origins/2" do
    test "rewrites loopback http and ws origins to a same-origin proxy path, preserving port" do
      body = ~s|fetch("http://localhost:5173/api");new WebSocket("ws://127.0.0.1:5173/hmr")|
      out = Rewrite.rewrite_loopback_origins(body, "ws-1")

      assert out =~ ~s|fetch("/preview-proxy/ws-1/5173/api")|
      assert out =~ ~s|new WebSocket("/preview-proxy/ws-1/5173/hmr")|
    end

    test "leaves external origins untouched" do
      body = ~s|fetch("https://api.example.com/x");"http://localhost:5173/y"|
      out = Rewrite.rewrite_loopback_origins(body, "ws-1")

      assert out =~ ~s|https://api.example.com/x|
      assert out =~ ~s|/preview-proxy/ws-1/5173/y|
    end
  end
end
