defmodule DevIdeWeb.WorkspaceLive.Show.TerminalChromeTest do
  use ExUnit.Case, async: true

  alias DevIdeWeb.WorkspaceLive.Show.TerminalChrome

  describe "preview_proxied?/1" do
    test "true only for /preview-proxy/ display URLs" do
      assert TerminalChrome.preview_proxied?(%{display_url: "/preview-proxy/ws/3000/"})
      assert TerminalChrome.preview_proxied?(%{"display_url" => "/preview-proxy/ws/3000/app"})
      refute TerminalChrome.preview_proxied?(%{display_url: "http://localhost:3000/"})
      refute TerminalChrome.preview_proxied?(%{display_url: "/preview-artifacts/ws/x.png"})
      refute TerminalChrome.preview_proxied?(%{})
    end
  end

  describe "preview_iframe_sandbox/1" do
    test "proxied previews keep allow-same-origin for authenticated proxy loads" do
      sandbox = TerminalChrome.preview_iframe_sandbox(%{display_url: "/preview-proxy/ws/3000/"})

      assert sandbox =~ "allow-same-origin"
      assert sandbox =~ "allow-scripts"
    end

    test "direct/snapshot previews keep allow-same-origin" do
      assert TerminalChrome.preview_iframe_sandbox(%{display_url: "http://localhost:3000/"}) =~
               "allow-same-origin"

      assert TerminalChrome.preview_iframe_sandbox(%{display_url: "/preview-artifacts/ws/x.png"}) =~
               "allow-same-origin"
    end
  end
end
