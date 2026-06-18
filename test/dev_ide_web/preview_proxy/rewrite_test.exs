defmodule DevIdeWeb.PreviewProxy.RewriteTest do
  use ExUnit.Case, async: true

  alias DevIdeWeb.PreviewProxy.Rewrite

  describe "droppable_header?/1" do
    test "drops frame blockers regardless of case" do
      assert Rewrite.droppable_header?("X-Frame-Options")
      assert Rewrite.droppable_header?("content-security-policy")
      assert Rewrite.droppable_header?("Content-Security-Policy-Report-Only")
      assert Rewrite.droppable_header?("strict-transport-security")
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
        {"Cache-Control", "no-store"},
        {"Content-Length", "1234"}
      ]

      out = Rewrite.forward_headers(headers)

      assert {"content-type", "text/html"} in out
      assert {"cache-control", "no-store"} in out

      refute Enum.any?(out, fn {k, _} ->
               k in ~w(x-frame-options content-security-policy content-length)
             end)
    end

    test "handles Req's map shape with list values" do
      headers = %{"content-type" => ["application/json"], "x-frame-options" => ["SAMEORIGIN"]}
      out = Rewrite.forward_headers(headers)

      assert {"content-type", "application/json"} in out
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

  describe "inject_base/2" do
    test "inserts <base> right after <head>" do
      html = "<html><head><title>x</title></head><body>hi</body></html>"
      out = Rewrite.inject_base(html, "/preview-proxy/ws/3000/")

      assert out =~ ~s(<head><base href="/preview-proxy/ws/3000/"><title>)
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
  end

  describe "first_header/2" do
    test "reads list and map shapes" do
      assert Rewrite.first_header([{"Content-Type", "text/css"}], "content-type") == "text/css"
      assert Rewrite.first_header(%{"content-type" => ["text/css"]}, "content-type") == "text/css"
      assert Rewrite.first_header([], "content-type") == nil
    end
  end
end
