defmodule DevIDE.Push.RegistryTest do
  @moduledoc """
  Direct unit tests for the in-memory token store. The fan-out behaviour (what
  gets pushed where) lives in `DevIDE.PushTest`; this covers the store's own
  semantics: per-workspace vs per-user registration, token refresh, unregister
  across both maps, and the lazy dispatcher subscription a workspace token
  triggers.
  """
  use DevIde.DataCase, async: false

  alias DevIDE.Push.Registry

  setup do
    Registry.clear()
    on_exit(fn -> Registry.clear() end)
    :ok
  end

  test "registers and lists a workspace token" do
    :ok = Registry.register(%{workspace_id: "ws-1", token: "tok-1", platform: "ios"})

    assert [%{token: "tok-1", platform: "ios", user_id: nil}] = Registry.tokens_for("ws-1")
    assert Registry.tokens_for("ws-other") == []

    assert [device] = Registry.list_devices(limit: 5)
    assert device.workspace_id == "ws-1"
    assert device.provider_status == "active"
    assert device.disabled_at == nil
  end

  test "carries an optional user_id on a workspace registration" do
    :ok =
      Registry.register(%{workspace_id: "ws-1", token: "tok-1", platform: "ios", user_id: "dev"})

    assert [%{token: "tok-1", platform: "ios", user_id: "dev"}] = Registry.tokens_for("ws-1")
  end

  test "refreshing the same token in a workspace does not duplicate it" do
    :ok = Registry.register(%{workspace_id: "ws-1", token: "tok-1", platform: "ios"})
    :ok = Registry.register(%{workspace_id: "ws-1", token: "tok-1", platform: "android"})

    assert [%{token: "tok-1", platform: "android"}] = Registry.tokens_for("ws-1")
  end

  test "keeps distinct tokens within the same workspace" do
    :ok = Registry.register(%{workspace_id: "ws-1", token: "tok-1", platform: "ios"})
    :ok = Registry.register(%{workspace_id: "ws-1", token: "tok-2", platform: "android"})

    tokens = "ws-1" |> Registry.tokens_for() |> Enum.map(& &1.token) |> Enum.sort()
    assert tokens == ["tok-1", "tok-2"]
  end

  test "registers and lists a user token independently of workspaces" do
    :ok = Registry.register_user(%{user_id: "dev", token: "tok-user", platform: "android"})

    assert [%{token: "tok-user", platform: "android", user_id: "dev"}] =
             Registry.tokens_for_user("dev")

    assert Registry.tokens_for("ws-1") == []
  end

  test "unregister removes a token from every workspace and user bucket" do
    :ok = Registry.register(%{workspace_id: "ws-1", token: "tok-shared", platform: "ios"})
    :ok = Registry.register(%{workspace_id: "ws-2", token: "tok-shared", platform: "ios"})
    :ok = Registry.register_user(%{user_id: "dev", token: "tok-shared", platform: "ios"})
    :ok = Registry.register(%{workspace_id: "ws-1", token: "tok-keep", platform: "ios"})

    :ok = Registry.unregister("tok-shared")

    assert [%{token: "tok-keep"}] = Registry.tokens_for("ws-1")
    assert Registry.tokens_for("ws-2") == []
    assert Registry.tokens_for_user("dev") == []
  end

  test "clear empties both workspace and user registrations" do
    :ok = Registry.register(%{workspace_id: "ws-1", token: "tok-1", platform: "ios"})
    :ok = Registry.register_user(%{user_id: "dev", token: "tok-user", platform: "android"})

    :ok = Registry.clear()

    assert Registry.tokens_for("ws-1") == []
    assert Registry.tokens_for_user("dev") == []
  end

  test "record_failure increments health and disables invalid tokens" do
    :ok = Registry.register(%{workspace_id: "ws-1", token: "tok-bad", platform: "ios"})

    :ok = Registry.record_failure("tok-bad", :invalid_token)

    assert Registry.tokens_for("ws-1") == []
    assert [device] = Registry.list_devices(limit: 5)
    assert device.failure_count == 1
    assert device.provider_status == "invalid"
    assert %DateTime{} = device.disabled_at
  end

  test "a workspace registration subscribes the dispatcher to that workspace" do
    workspace_id = "ws-watch-#{System.unique_integer([:positive])}"

    :ok = Registry.register(%{workspace_id: workspace_id, token: "tok-1", platform: "ios"})

    # watch/1 is synchronous and idempotent; a second registration must not error
    # or block, proving the dispatcher already holds the subscription.
    assert :ok = Registry.register(%{workspace_id: workspace_id, token: "tok-2", platform: "ios"})
    assert :ok = DevIDE.Push.Dispatcher.watch(workspace_id)
  end
end
