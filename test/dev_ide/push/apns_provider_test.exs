defmodule DevIDE.Push.APNSProviderTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Push.APNSProvider

  @notification %{
    workspace_id: "ws-7",
    action: "mobile.needs_review",
    title: "2 items need review",
    reason: "Review required before work continues",
    card_id: "needs_review:ws-7:run-1",
    card_type: "needs_review",
    session_id: "run-1",
    origin_id: "origin-local-mac",
    origin_name: "Local Mac",
    locator: %{origin_id: "origin-local-mac", workspace_id: "ws-7", session_id: "run-1"},
    deep_link: "devide://review/needs_review%3Aws-7%3Arun-1"
  }

  setup do
    prev = Application.get_env(:dev_ide, APNSProvider)

    Application.put_env(:dev_ide, APNSProvider,
      team_id: "TEAM123456",
      key_id: "KEY1234567",
      topic: "com.example.devide_mob",
      private_key: private_key_pem(),
      http_client: DevIDE.Push.APNS.StubHTTP,
      now_fun: fn -> 1_800_000_000 end
    )

    Application.put_env(:dev_ide, :apns_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:dev_ide, :apns_test_pid)
      Application.delete_env(:dev_ide, :apns_stub_response)

      if prev,
        do: Application.put_env(:dev_ide, APNSProvider, prev),
        else: Application.delete_env(:dev_ide, APNSProvider)
    end)

    :ok
  end

  test "builds an APNs alert request for iOS APNs tokens" do
    assert :ok = APNSProvider.push("apns-device-token", "ios", @notification)

    assert_receive {:apns_request, url, headers, body}, 1_000

    assert url == "https://api.sandbox.push.apple.com/3/device/apns-device-token"
    assert {"apns-topic", "com.example.devide_mob"} in headers
    assert {"apns-push-type", "alert"} in headers
    assert {"apns-priority", "10"} in headers

    {"authorization", "bearer " <> jwt} =
      Enum.find(headers, fn {key, _value} -> key == "authorization" end)

    [header, claims, signature] = String.split(jwt, ".")
    assert signature |> Base.url_decode64!(padding: false) |> byte_size() == 64
    assert decode_jwt_segment(header) == %{"alg" => "ES256", "kid" => "KEY1234567"}
    assert decode_jwt_segment(claims) == %{"iss" => "TEAM123456", "iat" => 1_800_000_000}

    assert body["aps"]["alert"] == %{
             "title" => "2 items need review",
             "body" => "Review required before work continues"
           }

    assert body["aps"]["sound"] == "default"
    assert body["id"] == "needs_review:ws-7:run-1"
    assert body["workspace_id"] == "ws-7"
    assert body["action"] == "mobile.needs_review"
    assert body["deep_link"] == "devide://review/needs_review%3Aws-7%3Arun-1"
    assert body["card_id"] == "needs_review:ws-7:run-1"
    assert body["card_type"] == "needs_review"
    assert body["session_id"] == "run-1"
    assert body["origin_id"] == "origin-local-mac"
    assert body["origin_name"] == "Local Mac"

    assert body["locator"] == %{
             origin_id: "origin-local-mac",
             workspace_id: "ws-7",
             session_id: "run-1"
           }
  end

  test "reports readiness for configured iOS/APNs delivery" do
    assert :ok = APNSProvider.configured_for?("ios")
    assert :ok = APNSProvider.configured_for?("apns")
    assert {:error, :unsupported_platform} = APNSProvider.configured_for?("android")
  end

  test "uses production APNs endpoint when configured" do
    Application.put_env(:dev_ide, APNSProvider,
      team_id: "TEAM123456",
      key_id: "KEY1234567",
      topic: "com.example.devide_mob",
      private_key: private_key_pem(),
      http_client: DevIDE.Push.APNS.StubHTTP,
      environment: "production"
    )

    assert :ok = APNSProvider.push("token", "ios", @notification)
    assert_receive {:apns_request, url, _headers, _body}, 1_000
    assert url == "https://api.push.apple.com/3/device/token"
  end

  test "returns invalid token errors for APNs bad token responses" do
    Application.put_env(
      :dev_ide,
      :apns_stub_response,
      {:ok, %{status: 400, body: %{"reason" => "BadDeviceToken"}}}
    )

    assert {:error, {:invalid_token, {:apns_status, 400, "BadDeviceToken"}}} =
             APNSProvider.push("dead-token", "ios", @notification)
  end

  test "does not send non-iOS platforms through APNs" do
    assert {:error, :unsupported_platform} = APNSProvider.push("token", "android", @notification)
    refute_receive {:apns_request, _, _, _}, 100
  end

  test "errors clearly when APNs config is incomplete" do
    Application.put_env(:dev_ide, APNSProvider, key_id: "KEY1234567")

    assert {:error, :no_team_id} = APNSProvider.push("token", "ios", @notification)
    assert {:error, :no_team_id} = APNSProvider.configured?()
  end

  defp decode_jwt_segment(segment) do
    segment
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
  end

  defp private_key_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
  end
end
