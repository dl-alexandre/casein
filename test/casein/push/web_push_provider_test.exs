defmodule Casein.Push.WebPushProviderTest do
  use ExUnit.Case, async: true

  alias Casein.Push.WebPushProvider

  # No VAPID config is set in the test env, so the provider must be inert.
  test "is unconfigured without VAPID keys" do
    assert WebPushProvider.configured?() == {:error, :push_provider_unconfigured}
    assert WebPushProvider.configured_for?("web") == {:error, :push_provider_unconfigured}
  end

  test "push is a no-op error when unconfigured" do
    assert WebPushProvider.push("https://push/endpoint", "web", %{title: "hi"}) ==
             {:error, :push_provider_unconfigured}
  end

  describe "payload/1" do
    test "names the workspace in the title" do
      payload =
        WebPushProvider.payload(%{
          workspace_id: "ws-1",
          workspace_name: "dev-ide",
          title: "Agent needs clarification",
          reason: "Which branch?"
        })

      assert payload["title"] == "dev-ide — Agent needs clarification"
      assert payload["body"] == "Which branch?"
      assert payload["workspace_name"] == "dev-ide"
    end

    test "falls back to the bare title when the workspace name is unknown" do
      payload = WebPushProvider.payload(%{workspace_id: "ws-1", title: "Agent went quiet"})

      assert payload["title"] == "Agent went quiet"
      refute Map.has_key?(payload, "workspace_name")
    end

    test "points the click at the workspace, not the scratch root" do
      payload =
        WebPushProvider.payload(%{
          workspace_id: "ws-1",
          session_id: "u-dev-abc",
          deep_link: "casein://review/card-1"
        })

      assert payload["url"] == "/workspaces/ws-1?session=u-dev-abc"
      assert payload["session_id"] == "u-dev-abc"
    end

    test "carries the locator so the page can attach in an already-open window" do
      payload =
        WebPushProvider.payload(%{
          workspace_id: "ws-1",
          locator: %{session: "u-dev-abc", window: "@1", tmux_session: "casein_ws1"}
        })

      assert payload["session_id"] == "u-dev-abc"
      assert payload["window_id"] == "@1"
      assert payload["tmux_session"] == "casein_ws1"
    end

    test "tags per waiting agent so one workspace can show two notifications" do
      first = WebPushProvider.payload(%{workspace_id: "ws-1", attention_key: "agent-a"})
      second = WebPushProvider.payload(%{workspace_id: "ws-1", attention_key: "agent-b"})

      assert first["tag"] == "casein:agent-a"
      assert second["tag"] == "casein:agent-b"
    end

    test "falls back to the workspace tag without an attention identity" do
      assert WebPushProvider.payload(%{workspace_id: "ws-1"})["tag"] == "casein:ws-1"
      assert WebPushProvider.payload(%{})["tag"] == "casein"
    end
  end

  test "rejects non-web platforms" do
    assert WebPushProvider.configured_for?("ios") == {:error, {:unsupported_platform, "ios"}}

    assert WebPushProvider.push("t", "android", %{}) ==
             {:error, {:unsupported_platform, "android"}}
  end
end
