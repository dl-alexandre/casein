defmodule DevIDE.Push.WebPushProviderTest do
  use ExUnit.Case, async: true

  alias DevIDE.Push.WebPushProvider

  # No VAPID config is set in the test env, so the provider must be inert.
  test "is unconfigured without VAPID keys" do
    assert WebPushProvider.configured?() == {:error, :push_provider_unconfigured}
    assert WebPushProvider.configured_for?("web") == {:error, :push_provider_unconfigured}
  end

  test "push is a no-op error when unconfigured" do
    assert WebPushProvider.push("https://push/endpoint", "web", %{title: "hi"}) ==
             {:error, :push_provider_unconfigured}
  end

  test "rejects non-web platforms" do
    assert WebPushProvider.configured_for?("ios") == {:error, {:unsupported_platform, "ios"}}

    assert WebPushProvider.push("t", "android", %{}) ==
             {:error, {:unsupported_platform, "android"}}
  end
end
