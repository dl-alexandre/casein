defmodule DevIdeWeb.DesktopTerminalLiveTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "uses the DevIDE cockpit shell without generated Phoenix navigation", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/desktop-terminal")

    assert html =~ ~s(id="desktop-cockpit-header")
    assert html =~ "Local desktop"
    assert html =~ "PowerShell"
    assert html =~ "Windows"
    refute html =~ "phoenixframework.org"
    refute html =~ ">Get Started<"
  end
end
