defmodule DevIdeWeb.PageHTMLTest do
  use DevIDE.TestCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders home.html" do
    html = render_to_string(DevIdeWeb.PageHTML, "home", "html", flash: %{})

    assert html =~ "Phoenix Framework"
    assert html =~ "Peace of mind from prototype to production."
    assert html =~ "Guides &amp; Docs"
    assert html =~ "Source Code"
  end
end
