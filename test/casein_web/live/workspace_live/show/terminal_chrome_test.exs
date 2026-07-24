defmodule CaseinWeb.WorkspaceLive.Show.TerminalChromeTest do
  use Casein.TestCase, async: true

  alias CaseinWeb.WorkspaceLive.Show.TerminalChrome

  describe "preview_proxied?/1" do
    test "true only for /preview-proxy/ display URLs" do
      assert TerminalChrome.preview_proxied?(%{display_url: "/preview-proxy/ws/3000/"})
      assert TerminalChrome.preview_proxied?(%{"display_url" => "/preview-proxy/ws/3000/app"})
      refute TerminalChrome.preview_proxied?(%{display_url: "http://localhost:3000/"})
      refute TerminalChrome.preview_proxied?(%{display_url: "/preview-artifacts/ws/x.png"})
      refute TerminalChrome.preview_proxied?(%{})
    end
  end

  describe "preview_snapshot_mode?/1 and preview_playback_mode?/1" do
    test "a PNG snapshot artifact is snapshot mode, not playback" do
      png = %{display_url: "https://app/preview-artifacts/ws/7.png?fit=preview"}
      assert TerminalChrome.preview_snapshot_mode?(png)
      refute TerminalChrome.preview_playback_mode?(png)
    end

    test "a webm recording is playback mode, not snapshot (so video controls stay clickable)" do
      webm = %{display_url: "https://app/preview-artifacts/ws/rec.webm?fit=playback"}
      assert TerminalChrome.preview_playback_mode?(webm)
      refute TerminalChrome.preview_snapshot_mode?(webm)
    end

    test "a live app URL is neither" do
      live = %{display_url: "http://localhost:3000/"}
      refute TerminalChrome.preview_snapshot_mode?(live)
      refute TerminalChrome.preview_playback_mode?(live)
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
