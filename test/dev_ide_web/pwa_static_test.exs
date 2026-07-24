defmodule DevIdeWeb.PwaStaticTest do
  use DevIdeWeb.ConnCase, async: true

  test "site manifest is served with installable mobile metadata", %{conn: conn} do
    conn = get(conn, "/site.webmanifest")

    assert {:ok, manifest} = Jason.decode(response(conn, 200))
    assert manifest["name"] == "DevIDE"
    assert manifest["short_name"] == "DevIDE"
    assert manifest["start_url"] == "/"
    assert manifest["scope"] == "/"
    assert manifest["display"] == "standalone"
    assert manifest["theme_color"] == "#101114"

    icons = manifest["icons"]

    assert Enum.any?(
             icons,
             &match?(%{"src" => "/images/pwa-icon-192.png", "sizes" => "192x192"}, &1)
           )

    assert Enum.any?(
             icons,
             &match?(%{"src" => "/images/pwa-icon-512.png", "sizes" => "512x512"}, &1)
           )

    assert Enum.any?(
             icons,
             &match?(%{"src" => "/images/pwa-maskable-512.png", "purpose" => "maskable"}, &1)
           )
  end

  test "service worker is served and bypasses live authenticated surfaces", %{conn: conn} do
    conn = get(conn, "/service-worker.js")
    body = response(conn, 200)

    assert body =~ ~s("/api/")
    assert body =~ ~s("/live")
    assert body =~ ~s("/socket")
    assert body =~ ~s("/preview-proxy/")
    assert body =~ "networkFirstStatic"
    assert body =~ "/offline.html"
    assert body =~ "notificationclick"
    assert body =~ "DEVIDE_AGENT_QUIET_OPEN"
  end

  test "standalone PWA chrome respects iOS safe areas" do
    css = File.read!("assets/css/app.css")

    # black-translucent status bar paints over content; standalone shell must
    # clear the notch/Dynamic Island (top) and the home indicator (bottom).
    assert css =~ "safe-area-inset-top"
    assert css =~ "safe-area-inset-bottom"
    assert css =~ "display-mode: standalone"
  end

  test "viewport meta pins Chromium interactive-widget to resizes-visual" do
    root = File.read!("lib/dev_ide_web/components/layouts/root.html.heex")
    offline = File.read!("priv/static/offline.html")

    assert root =~ "interactive-widget=resizes-visual"
    assert offline =~ "interactive-widget=resizes-visual"
  end

  test "offline fallback is served as static HTML", %{conn: conn} do
    conn = get(conn, "/offline.html")
    body = response(conn, 200)

    assert body =~ "DevIDE is offline"
    assert body =~ "Terminal sessions, previews, and agent updates need a live connection"
  end
end
