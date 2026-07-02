defmodule DevIdeWebMacrosTest do
  use DevIDE.TestCase, async: true

  test "static_paths/0 lists application static assets" do
    paths = DevIdeWeb.static_paths()

    assert "assets" in paths
    assert "favicon.ico" in paths
    assert "whitehouse-preview.html" in paths
  end

  test "__using__(:html) provides verified routes and CoreComponents" do
    defmodule HtmlMacroTest do
      use DevIdeWeb, :html

      def home, do: ~p"/"
    end

    assert HtmlMacroTest.home() =~ "/"
    assert function_exported?(DevIdeWeb.CoreComponents, :flash, 1)
  end

  test "__using__(:controller) compiles a Phoenix controller" do
    defmodule ControllerMacroTest do
      use DevIdeWeb, :controller

      def hello(conn, _params), do: text(conn, "ok")
    end

    assert function_exported?(ControllerMacroTest, :hello, 2)
  end

  test "__using__(:live_view) compiles a LiveView module" do
    defmodule LiveViewMacroTest do
      use DevIdeWeb, :live_view

      def mount(_params, _session, socket), do: {:ok, socket}
    end

    assert function_exported?(LiveViewMacroTest, :mount, 3)
  end

  test "__using__(:live_component) compiles a LiveComponent module" do
    defmodule LiveComponentMacroTest do
      use DevIdeWeb, :live_component

      def update(assigns, socket), do: {:ok, assign(socket, assigns)}
    end

    assert function_exported?(LiveComponentMacroTest, :update, 2)
  end

  test "__using__(:channel) compiles a Phoenix channel" do
    defmodule ChannelMacroTest do
      use DevIdeWeb, :channel

      def join("topic", _payload, socket), do: {:ok, socket}
    end

    assert function_exported?(ChannelMacroTest, :join, 3)
  end

  test "__using__(:router) compiles a Phoenix router" do
    defmodule RouterMacroTest do
      use DevIdeWeb, :router

      get "/macro-test", DevIdeWeb.PageController, :home
    end

    assert function_exported?(RouterMacroTest, :__match_route__, 3)
  end
end
