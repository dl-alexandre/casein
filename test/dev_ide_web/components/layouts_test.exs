defmodule CaseinWeb.LayoutsTest do
  use Casein.TestCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Template, only: [render_to_string: 4]

  alias CaseinWeb.Layouts

  defp slot(content) do
    [%{__slot__: :inner_block, inner_block: fn _, _ -> content end}]
  end

  test "app layout renders navigation, slot content, and flash group" do
    html =
      render_component(&Layouts.app/1,
        flash: %{"info" => "Welcome"},
        inner_block: slot("<p>Inner content</p>")
      )

    assert html =~ "Inner content"
    assert html =~ "navbar"
    assert html =~ "flash-group"
    assert html =~ "Get Started"
  end

  test "flash_group renders connection error placeholders" do
    html = render_component(&Layouts.flash_group/1, flash: %{}, id: "layout-flash")

    assert html =~ ~s(id="layout-flash")
    assert html =~ ~s(id="client-error")
    assert html =~ ~s(id="server-error")
    assert html =~ "Attempting to reconnect"
  end

  test "theme_toggle renders system, light, and dark controls" do
    html = render_component(&Layouts.theme_toggle/1)

    assert html =~ ~s(data-phx-theme="system")
    assert html =~ ~s(data-phx-theme="light")
    assert html =~ ~s(data-phx-theme="dark")
    assert html =~ "hero-sun-micro"
    assert html =~ "hero-moon-micro"
  end

  test "root layout template renders the HTML skeleton" do
    html =
      render_to_string(Layouts, "root", "html",
        flash: %{},
        inner_content: "<main>Body</main>"
      )

    assert html =~ "<!DOCTYPE html>"
    assert html =~ ~s(rel="manifest" href="/site.webmanifest")
    assert html =~ ~s(name="apple-mobile-web-app-capable" content="yes")
    assert html =~ ~s(rel="apple-touch-icon" href="/images/apple-touch-icon.png")
    assert html =~ ~s(name="theme-color" content="#101114")
    assert html =~ ~s(href="/assets/css/app.css")
    assert html =~ "Body"
  end

  test "live layout renders browser alert opt-in trigger" do
    html =
      render_to_string(Layouts, "live", "html",
        flash: %{},
        inner_content: "<main>Body</main>"
      )

    assert html =~ ~s(id="browser-alert-opt-in")
    assert html =~ "data-devide-notification-permission"
    assert html =~ "Enable alerts"
    assert html =~ "Body"
  end
end
