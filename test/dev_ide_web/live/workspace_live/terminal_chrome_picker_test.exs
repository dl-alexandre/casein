defmodule DevIdeWeb.WorkspaceLive.Show.TerminalChromePickerTest do
  use ExUnit.Case, async: true

  alias DevIdeWeb.WorkspaceLive.Show.TerminalChrome

  test "pane_picker_label uses tab title for preview panes" do
    preview = %{display_url: "http://127.0.0.1:4000/workspaces/ws-1", title: "127.0.0.1:4000"}
    pane = %{id: "%2", current_path: "/tmp", current_command: "bash"}

    assert TerminalChrome.pane_picker_label(pane, preview) == "127.0.0.1:4000"
  end

  test "preview_favicon_url derives from page origin" do
    assert TerminalChrome.preview_favicon_url("https://devide.example.test/app") =~
             "favicons?domain=devide.example.test"
  end
end
