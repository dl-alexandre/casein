defmodule DevIDE.PushTest do
  @moduledoc """
  Covers the push pipeline end to end: a registered token receives a push when
  an alert-worthy audit event fires for its workspace — and nothing else does.
  Runs against the app-supervised `Registry`/`Dispatcher` with a stub provider.
  """
  use ExUnit.Case, async: false

  alias DevIDE.{Audit, Push}
  alias DevIDE.Mobile.UserObserver

  setup do
    prev_provider = Application.get_env(:dev_ide, :push_provider)
    prev_apns = Application.get_env(:dev_ide, DevIDE.Push.APNSProvider)
    Application.put_env(:dev_ide, :push_provider, DevIDE.Push.TestProvider)
    Application.put_env(:dev_ide, :push_test_pid, self())

    Push.Registry.clear()
    Audit.clear()

    on_exit(fn ->
      Push.Registry.clear()
      Audit.clear()
      Application.delete_env(:dev_ide, :push_test_pid)
      Application.delete_env(:dev_ide, :push_test_response)

      if prev_provider,
        do: Application.put_env(:dev_ide, :push_provider, prev_provider),
        else: Application.delete_env(:dev_ide, :push_provider)

      if prev_apns,
        do: Application.put_env(:dev_ide, DevIDE.Push.APNSProvider, prev_apns),
        else: Application.delete_env(:dev_ide, DevIDE.Push.APNSProvider)
    end)

    :ok
  end

  test "native provider readiness loads platform provider before checking config" do
    Application.put_env(:dev_ide, :push_provider, DevIDE.Push.NativeProvider)
    Application.delete_env(:dev_ide, DevIDE.Push.APNSProvider)

    assert {:error, :no_team_id} = Push.ready_for?("ios")
  end

  test "a registered token is pushed on an alert-worthy event" do
    :ok =
      Push.register(%{workspace_id: "pw-1", token: "tok-abc", platform: "ios", user_id: "dev"})

    Audit.emit(%{
      workspace_id: "pw-1",
      action: "policy.blocked",
      decision: :deny,
      reason: :not_allowlisted
    })

    assert_receive {:pushed, "tok-abc", "ios", notification}, 1_000
    assert notification.workspace_id == "pw-1"
    assert notification.title == "Blocked by policy"
    assert notification.reason == "not_allowlisted"
  end

  test "non-alert events do not push" do
    :ok = Push.register(%{workspace_id: "pw-1", token: "tok-abc", platform: "ios"})

    Audit.emit(%{workspace_id: "pw-1", action: "run.started", decision: :allow})

    refute_receive {:pushed, _, _, _}, 300
  end

  test "tokens only receive pushes for their own workspace" do
    :ok = Push.register(%{workspace_id: "pw-1", token: "tok-1", platform: "ios"})
    :ok = Push.register(%{workspace_id: "pw-2", token: "tok-2", platform: "android"})

    Audit.emit(%{workspace_id: "pw-2", action: "run.timed_out", decision: :allow})

    assert_receive {:pushed, "tok-2", "android", _}, 1_000
    refute_receive {:pushed, "tok-1", _, _}, 300
  end

  test "new needs_review cards push once to the matching user's device" do
    user_id = "push-user-#{System.unique_integer([:positive])}"
    other_user_id = "push-other-#{System.unique_integer([:positive])}"

    :ok = UserObserver.clear(user_id)
    :ok = UserObserver.clear(other_user_id)

    :ok =
      Push.register(%{
        workspace_id: "pw-1",
        token: "tok-user",
        platform: "ios",
        user_id: user_id
      })

    :ok =
      Push.register(%{
        workspace_id: "pw-1",
        token: "tok-other",
        platform: "ios",
        user_id: other_user_id
      })

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: "pw-1",
      workspace_name: "Push Workspace",
      session_id: "run-1",
      review_count: 2
    })

    assert_receive {:pushed, "tok-user", "ios", notification}, 1_000
    assert notification.action == "mobile.needs_review"
    assert notification.title == "2 items need review"
    assert notification.reason == "Review required before work continues"
    assert notification.workspace_id == "pw-1"
    assert notification.user_id == user_id
    assert notification.session_id == "run-1"
    assert notification.card_id == "needs_review:pw-1:run-1"
    assert notification.deep_link == "devide://review/needs_review%3Apw-1%3Arun-1"
    refute_receive {:pushed, "tok-other", "ios", _notification}, 300

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: "pw-1",
      workspace_name: "Push Workspace",
      session_id: "run-1",
      review_count: 3
    })

    refute_receive {:pushed, _, _, _}, 300
  end

  test "user-scoped tokens receive new needs_review cards without workspace registration" do
    user_id = "push-user-#{System.unique_integer([:positive])}"
    other_user_id = "push-other-#{System.unique_integer([:positive])}"

    :ok = UserObserver.clear(user_id)
    :ok = UserObserver.clear(other_user_id)

    :ok = Push.register_user(%{user_id: user_id, token: "tok-user", platform: "android"})
    :ok = Push.register_user(%{user_id: other_user_id, token: "tok-other", platform: "android"})

    assert Push.tokens_for("pw-user-scope") == []

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: "pw-user-scope",
      workspace_name: "User Push Workspace",
      session_id: "run-1",
      review_count: 1
    })

    assert_receive {:pushed, "tok-user", "android", notification}, 1_000
    assert notification.action == "mobile.needs_review"
    assert notification.user_id == user_id
    assert notification.workspace_id == "pw-user-scope"
    assert notification.card_id == "needs_review:pw-user-scope:run-1"
    refute_receive {:pushed, "tok-other", "android", _notification}, 300
  end

  test "mobile card dispatch dedupes user and workspace registrations for one token" do
    user_id = "push-user-#{System.unique_integer([:positive])}"
    :ok = UserObserver.clear(user_id)

    attrs = %{user_id: user_id, token: "tok-dupe", platform: "ios"}
    :ok = Push.register_user(attrs)
    :ok = Push.register(Map.put(attrs, :workspace_id, "pw-dupe"))

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: "pw-dupe",
      session_id: "run-1",
      review_count: 1
    })

    assert_receive {:pushed, "tok-dupe", "ios", _notification}, 1_000
    refute_receive {:pushed, "tok-dupe", "ios", _notification}, 300
  end

  test "unregister stops pushes for that token" do
    :ok = Push.register(%{workspace_id: "pw-1", token: "tok-gone", platform: "ios"})
    :ok = Push.unregister("tok-gone")

    Audit.emit(%{workspace_id: "pw-1", action: "policy.blocked", decision: :deny})

    refute_receive {:pushed, "tok-gone", _, _}, 300
  end

  test "invalid-token provider responses unregister the token" do
    Application.put_env(:dev_ide, :push_test_response, {:error, :invalid_token})

    :ok = Push.register(%{workspace_id: "pw-1", token: "tok-bad", platform: "ios"})

    Audit.emit(%{workspace_id: "pw-1", action: "policy.blocked", decision: :deny})

    assert_receive {:pushed, "tok-bad", "ios", _}, 1_000
    assert eventually(fn -> Push.tokens_for("pw-1") == [] end) == :ok
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: :timeout
end
