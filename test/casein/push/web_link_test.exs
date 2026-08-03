defmodule Casein.Push.WebLinkTest do
  use ExUnit.Case, async: true

  alias Casein.Push.WebLink

  test "rewrites a native casein:// deep link into a workspace URL" do
    # The regression: casein:// is unopenable in a browser, and falling back to
    # "/" mounts the scratch workspace instead of the one that pushed.
    url =
      WebLink.build(%{
        workspace_id: "ws-1",
        deep_link: "casein://review/needs_review%3Aws-1%3Asession-1"
      })

    assert url == "/workspaces/ws-1"
  end

  test "carries the card locator so the click lands on the waiting pane" do
    url =
      WebLink.build(%{
        workspace_id: "ws-1",
        session_id: "u-dev-abc",
        deep_link: "casein://review/card-1",
        locator: %{window: "@1", pane: "%2", tmux_session: "casein_ws1", tab: "terminal"}
      })

    assert %URI{path: "/workspaces/ws-1", query: query} = URI.parse(url)

    assert URI.decode_query(query) == %{
             "session" => "u-dev-abc",
             "window" => "@1",
             "pane" => "%2",
             "tmux_session" => "casein_ws1",
             "tab" => "terminal"
           }
  end

  test "falls back to the session in the locator when the notification has none" do
    url = WebLink.build(%{workspace_id: "ws-1", locator: %{session: "u-dev-xyz"}})

    assert url == "/workspaces/ws-1?session=u-dev-xyz"
  end

  test "an alert with no session opens the notifications drawer" do
    url = WebLink.build(%{workspace_id: "ws-1", notification_id: "n-1"})

    assert url == "/workspaces/ws-1?drawer=notifications"
  end

  test "keeps an http deep link verbatim" do
    url =
      WebLink.build(%{workspace_id: "ws-1", deep_link: "https://casein.example/workspaces/ws-9"})

    assert url == "https://casein.example/workspaces/ws-9"
  end

  test "percent-encodes a workspace id" do
    assert WebLink.build(%{workspace_id: "ws/1 2"}) == "/workspaces/ws%2F1+2"
  end

  test "falls back to the root only without a workspace" do
    assert WebLink.build(%{}) == "/"
    assert WebLink.build(%{workspace_id: nil, deep_link: "casein://session/"}) == "/"
  end
end
