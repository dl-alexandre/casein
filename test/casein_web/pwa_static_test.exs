defmodule CaseinWeb.PwaStaticTest do
  use CaseinWeb.ConnCase, async: true

  test "site manifest is served with installable mobile metadata", %{conn: conn} do
    conn = get(conn, "/site.webmanifest")

    assert {:ok, manifest} = Jason.decode(response(conn, 200))
    assert manifest["name"] == "Casein"
    assert manifest["short_name"] == "Casein"
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
    # clear the notch/Dynamic Island (top), the home indicator (bottom), and —
    # in landscape on a coarse pointer — the sensor housing on the side edges.
    assert css =~ "safe-area-inset-top"
    assert css =~ "safe-area-inset-bottom"
    assert css =~ "safe-area-inset-left"
    assert css =~ "safe-area-inset-right"
    assert css =~ "display-mode: standalone"
    assert css =~ "orientation: landscape"
    # iOS re-inflates text after rotation unless autosizing is pinned; the
    # terminal grid is measured in px so an autosized font mis-sizes it.
    assert css =~ "text-size-adjust"
  end

  test "viewport meta pins Chromium interactive-widget to resizes-visual" do
    root = File.read!("lib/casein_web/components/layouts/root.html.heex")
    offline = File.read!("priv/static/offline.html")

    assert root =~ "interactive-widget=resizes-visual"
    assert offline =~ "interactive-widget=resizes-visual"
  end

  test "iOS terminal input does not trigger focus zoom" do
    css = File.read!("assets/css/app.css")

    assert css =~ ~s(textarea[data-ghostty-input="true"])
    assert css =~ "font-size: 16px !important"
    assert css =~ "@supports (-webkit-touch-callout: none)"
    assert css =~ "@media (pointer: coarse)"
  end

  test "offline fallback is served as static HTML", %{conn: conn} do
    conn = get(conn, "/offline.html")
    body = response(conn, 200)

    assert body =~ "Casein is offline"
    assert body =~ "Terminal sessions, previews, and agent updates need a live connection"
  end
end
