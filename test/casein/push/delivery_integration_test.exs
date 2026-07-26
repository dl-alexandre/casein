defmodule Casein.Push.DeliveryIntegrationTest do
  @moduledoc """
  Full-stack offline proof that a push actually leaves the building.

  Other suites test the halves in isolation: `Casein.PushTest` drives the
  dispatcher into a fake provider, and the provider tests drive a provider into
  a stub HTTP client. This suite joins them — a real spine event flows through
  the app-supervised `Dispatcher`, the `NativeProvider` platform router, the
  real `FCMProvider`/`APNSProvider` (real JWT/OAuth headers and JSON envelope),
  and finally hits the injectable HTTP seam — so we assert the exact bytes that
  would reach FCM/APNs without contacting Apple or Google.

  Routing is exercised end to end: an iOS workspace token gets the APNs
  envelope for an audit alert; an Android user token gets the FCM envelope for a
  needs_review card.
  """
  use Casein.DataCase, async: false

  alias Casein.{Audit, Push}
  alias Casein.Mobile.UserObserver
  alias Casein.Push.{APNSProvider, FCMProvider}

  setup do
    prev_provider = Application.get_env(:casein, :push_provider)
    prev_fcm = Application.get_env(:casein, FCMProvider)
    prev_apns = Application.get_env(:casein, APNSProvider)

    # The real production-shaped provider: route by platform, with both
    # transports configured to send through the test HTTP seam.
    Application.put_env(:casein, :push_provider, Push.NativeProvider)

    Application.put_env(:casein, FCMProvider,
      project_id: "demo-project",
      access_token_fun: fn -> {:ok, "ya29.integration-token"} end,
      http_client: Casein.Push.FCM.StubHTTP
    )

    Application.put_env(:casein, APNSProvider,
      team_id: "TEAM123456",
      key_id: "KEY1234567",
      topic: "com.example.casein_mob",
      private_key: private_key_pem(),
      http_client: Casein.Push.APNS.StubHTTP,
      now_fun: fn -> 1_800_000_000 end
    )

    Application.put_env(:casein, :fcm_test_pid, self())
    Application.put_env(:casein, :apns_test_pid, self())

    Push.Registry.clear()
    Audit.clear()

    on_exit(fn ->
      Push.Registry.clear()
      Audit.clear()
      Application.delete_env(:casein, :fcm_test_pid)
      Application.delete_env(:casein, :apns_test_pid)
      restore(:push_provider, prev_provider)
      restore_module(FCMProvider, prev_fcm)
      restore_module(APNSProvider, prev_apns)
    end)

    :ok
  end

  test "an audit alert reaches APNs as a fully-formed request for an iOS token" do
    workspace_id = "ws-apns-#{System.unique_integer([:positive])}"

    :ok =
      Push.register(%{workspace_id: workspace_id, token: "ios-device", platform: "ios"})

    Audit.emit(%{
      workspace_id: workspace_id,
      action: "policy.blocked",
      decision: :deny,
      reason: :not_allowlisted
    })

    assert_receive {:apns_request, url, headers, body}, 1_000
    refute_receive {:fcm_request, _, _, _}, 100

    assert url == "https://api.sandbox.push.apple.com/3/device/ios-device"
    assert {"apns-topic", "com.example.casein_mob"} in headers
    assert {"apns-push-type", "alert"} in headers
    assert {"apns-priority", "10"} in headers

    {"authorization", "bearer " <> jwt} =
      Enum.find(headers, fn {key, _value} -> key == "authorization" end)

    [header, claims, signature] = String.split(jwt, ".")
    assert signature |> Base.url_decode64!(padding: false) |> byte_size() == 64
    assert decode_segment(header) == %{"alg" => "ES256", "kid" => "KEY1234567"}
    assert decode_segment(claims) == %{"iss" => "TEAM123456", "iat" => 1_800_000_000}

    assert body["aps"]["alert"] == %{
             "title" => "Blocked by policy",
             "body" => "not_allowlisted"
           }

    assert body["action"] == "policy.blocked"
    assert body["workspace_id"] == workspace_id
    assert body["deep_link"] == "casein://session/#{workspace_id}"
  end

  test "a needs_review card reaches FCM as a fully-formed request for an Android token" do
    user_id = unique_user("push-user")
    workspace_id = "ws-fcm-#{System.unique_integer([:positive])}"
    :ok = UserObserver.clear(user_id)

    :ok = Push.register_user(%{user_id: user_id, token: "android-device", platform: "android"})

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      workspace_name: "Push Workspace",
      session_id: "run-1",
      review_count: 2
    })

    assert_receive {:fcm_request, url, headers, body}, 1_000
    refute_receive {:apns_request, _, _, _}, 100

    assert url == "https://fcm.googleapis.com/v1/projects/demo-project/messages:send"
    assert {"authorization", "Bearer ya29.integration-token"} in headers

    message = body["message"]
    assert message["token"] == "android-device"

    assert message["notification"] == %{
             "title" => "2 items need review",
             "body" => "Review required before work continues"
           }

    assert message["android"]["priority"] == "high"

    data = message["data"]
    assert data["action"] == "mobile.needs_review"
    assert data["card_type"] == "needs_review"
    assert data["workspace_id"] == workspace_id
    assert data["session_id"] == "run-1"
    assert data["card_id"] == "needs_review:#{workspace_id}:run-1"
    assert is_binary(data["origin_id"])

    deep_link = URI.parse(data["deep_link"])
    assert deep_link.scheme == "casein"
    assert deep_link.host == "review"
    assert deep_link.path == "/needs_review%3A#{workspace_id}%3Arun-1"

    assert URI.decode_query(deep_link.query) == %{
             "origin_id" => data["origin_id"],
             "session_id" => "run-1",
             "workspace_id" => workspace_id
           }
  end

  test "run.approval_requested audit events do not double-push (cards own that path)" do
    workspace_id = "ws-approval-#{System.unique_integer([:positive])}"

    :ok = Push.register(%{workspace_id: workspace_id, token: "ios-device", platform: "ios"})

    Audit.emit(%{
      workspace_id: workspace_id,
      action: "run.approval_requested",
      decision: :allow
    })

    refute_receive {:apns_request, _, _, _}, 300
    refute_receive {:fcm_request, _, _, _}, 100
  end

  defp decode_segment(segment) do
    segment |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp private_key_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp restore_module(module, nil), do: Application.delete_env(:casein, module)
  defp restore_module(module, value), do: Application.put_env(:casein, module, value)

  defp unique_user(prefix) do
    user_id = "#{prefix}-#{System.unique_integer([:positive])}"
    on_exit(fn -> UserObserver.stop(user_id) end)
    user_id
  end
end
