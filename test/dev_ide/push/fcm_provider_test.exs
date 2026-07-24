defmodule Casein.Push.FCMProviderTest do
  @moduledoc """
  Exercises `Casein.Push.FCMProvider` against a stubbed HTTP transport — proving
  the FCM v1 envelope, auth header, and deep-link without network or credentials.
  """
  use Casein.TestCase, async: false

  alias Casein.Push.FCMProvider
  alias Casein.Push.FCMToken

  @notification %{
    workspace_id: "ws-7",
    action: "policy.blocked",
    title: "Blocked by policy",
    reason: "not_allowlisted",
    at: ~U[2026-06-26 12:00:00Z]
  }

  setup do
    prev = Application.get_env(:dev_ide, FCMProvider)
    prev_token = Application.get_env(:dev_ide, FCMToken)

    Application.put_env(:dev_ide, FCMProvider,
      project_id: "demo-project",
      access_token_fun: fn -> {:ok, "ya29.test-token"} end,
      http_client: Casein.Push.FCM.StubHTTP
    )

    Application.put_env(:dev_ide, :fcm_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:dev_ide, :fcm_test_pid)
      Application.delete_env(:dev_ide, :fcm_stub_response)

      if prev,
        do: Application.put_env(:dev_ide, FCMProvider, prev),
        else: Application.delete_env(:dev_ide, FCMProvider)

      if prev_token,
        do: Application.put_env(:dev_ide, FCMToken, prev_token),
        else: Application.delete_env(:dev_ide, FCMToken)
    end)

    :ok
  end

  test "builds a valid FCM v1 request and returns :ok on 2xx" do
    assert :ok = FCMProvider.push("device-token-xyz", "android", @notification)

    assert_receive {:fcm_request, url, headers, body}, 1_000
    assert url == "https://fcm.googleapis.com/v1/projects/demo-project/messages:send"
    assert {"authorization", "Bearer ya29.test-token"} in headers

    message = body["message"]
    assert message["token"] == "device-token-xyz"
    assert message["notification"]["title"] == "Blocked by policy"
    assert message["notification"]["body"] == "not_allowlisted"
    assert message["data"]["workspace_id"] == "ws-7"
    assert message["data"]["action"] == "policy.blocked"
    assert message["data"]["deep_link"] == "devide://session/ws-7"

    assert Jason.decode!(message["data"]["mob_notification_json"]) == %{
             "id" => "push:ws-7",
             "title" => "Blocked by policy",
             "body" => "not_allowlisted",
             "source" => "push",
             "data" => %{
               "workspace_id" => "ws-7",
               "action" => "policy.blocked",
               "deep_link" => "devide://session/ws-7"
             }
           }

    assert message["android"]["priority"] == "high"
  end

  test "reports readiness for configured Android/FCM delivery" do
    assert :ok = FCMProvider.configured_for?("android")
    assert :ok = FCMProvider.configured_for?("fcm")
    assert {:error, :unsupported_platform} = FCMProvider.configured_for?("ios")
  end

  test "returns an error on a non-2xx FCM response" do
    Application.put_env(
      :dev_ide,
      :fcm_stub_response,
      {:ok, %{status: 404, body: %{"error" => "NOT_FOUND"}}}
    )

    assert {:error, {:fcm_status, 404}} = FCMProvider.push("dead-token", "android", @notification)
  end

  test "rejects native iOS APNs tokens without sending them to FCM" do
    assert {:error, :unsupported_platform} = FCMProvider.push("apns-token", "ios", @notification)
    refute_receive {:fcm_request, _url, _headers, _body}, 100
  end

  test "falls back to a generic body when the alert has no reason" do
    assert :ok = FCMProvider.push("t", "android", Map.delete(@notification, :reason))

    assert_receive {:fcm_request, _url, _headers, body}, 1_000
    assert body["message"]["notification"]["body"] == "Tap to open the session."
  end

  test "uses review deep-link metadata when supplied" do
    notification =
      Map.merge(@notification, %{
        action: "mobile.needs_review",
        card_id: "needs_review:ws-7:run-1",
        card_type: "needs_review",
        session_id: "run-1",
        deep_link: "devide://review/needs_review%3Aws-7%3Arun-1"
      })

    assert :ok = FCMProvider.push("t", "android", notification)

    assert_receive {:fcm_request, _url, _headers, body}, 1_000
    data = body["message"]["data"]
    assert data["action"] == "mobile.needs_review"
    assert data["deep_link"] == "devide://review/needs_review%3Aws-7%3Arun-1"
    assert data["card_id"] == "needs_review:ws-7:run-1"
    assert data["card_type"] == "needs_review"
    assert data["session_id"] == "run-1"

    mob_payload = Jason.decode!(data["mob_notification_json"])
    assert mob_payload["id"] == "needs_review:ws-7:run-1"
    assert mob_payload["source"] == "push"
    assert mob_payload["data"]["card_id"] == "needs_review:ws-7:run-1"
    assert mob_payload["data"]["deep_link"] == "devide://review/needs_review%3Aws-7%3Arun-1"
  end

  test "infers project id from FCMToken service-account config" do
    Application.put_env(:dev_ide, FCMProvider,
      access_token_fun: fn -> {:ok, "ya29.test-token"} end,
      http_client: Casein.Push.FCM.StubHTTP
    )

    Application.put_env(:dev_ide, FCMToken,
      service_account: %{
        project_id: "inferred-project",
        client_email: "firebase-adminsdk@example.iam.gserviceaccount.com"
      }
    )

    assert :ok = FCMProvider.push("t", "android", @notification)
    assert_receive {:fcm_request, url, _headers, _body}, 1_000
    assert url == "https://fcm.googleapis.com/v1/projects/inferred-project/messages:send"
  end

  test "errors cleanly when no access-token source is configured" do
    Application.put_env(:dev_ide, FCMProvider,
      project_id: "demo-project",
      http_client: Casein.Push.FCM.StubHTTP
    )

    assert {:error, :no_access_token_fun} = FCMProvider.push("t", "android", @notification)
    assert {:error, :no_access_token_fun} = FCMProvider.configured?()
  end

  test "errors cleanly when no project is configured" do
    Application.put_env(:dev_ide, FCMProvider, access_token_fun: fn -> {:ok, "t"} end)

    assert {:error, :no_project_id} = FCMProvider.push("t", "android", @notification)
    assert {:error, :no_project_id} = FCMProvider.configured?()
  end
end
