defmodule DevIDE.Push.NativeProviderTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Push.{APNSProvider, FCMProvider, NativeProvider}

  @notification %{workspace_id: "ws-1", action: "policy.blocked", title: "Blocked"}

  setup do
    prev_fcm = Application.get_env(:dev_ide, FCMProvider)
    prev_apns = Application.get_env(:dev_ide, APNSProvider)

    Application.put_env(:dev_ide, FCMProvider,
      project_id: "demo-project",
      access_token_fun: fn -> {:ok, "ya29.test-token"} end,
      http_client: DevIDE.Push.FCM.StubHTTP
    )

    Application.put_env(:dev_ide, APNSProvider,
      team_id: "TEAM123456",
      key_id: "KEY1234567",
      topic: "com.example.devide_mob",
      private_key: private_key_pem(),
      http_client: DevIDE.Push.APNS.StubHTTP
    )

    Application.put_env(:dev_ide, :fcm_test_pid, self())
    Application.put_env(:dev_ide, :apns_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:dev_ide, :fcm_test_pid)
      Application.delete_env(:dev_ide, :apns_test_pid)

      if prev_fcm,
        do: Application.put_env(:dev_ide, FCMProvider, prev_fcm),
        else: Application.delete_env(:dev_ide, FCMProvider)

      if prev_apns,
        do: Application.put_env(:dev_ide, APNSProvider, prev_apns),
        else: Application.delete_env(:dev_ide, APNSProvider)
    end)

    :ok
  end

  test "routes Android tokens to FCM" do
    assert :ok = NativeProvider.push("android-token", "android", @notification)
    assert_receive {:fcm_request, _url, _headers, body}, 1_000
    assert body["message"]["token"] == "android-token"
    refute_receive {:apns_request, _, _, _}, 100
  end

  test "reports readiness for routed native platforms" do
    assert :ok = NativeProvider.configured_for?("android")
    assert :ok = NativeProvider.configured_for?("ios")
    assert {:error, :unsupported_platform} = NativeProvider.configured_for?("webos")
  end

  test "routes iOS tokens to APNs" do
    assert :ok = NativeProvider.push("ios-token", "ios", @notification)
    assert_receive {:apns_request, url, _headers, _body}, 1_000
    assert url == "https://api.sandbox.push.apple.com/3/device/ios-token"
    refute_receive {:fcm_request, _, _, _}, 100
  end

  test "rejects unknown platforms" do
    assert {:error, :unsupported_platform} =
             NativeProvider.push("token", "webos", @notification)
  end

  defp private_key_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
  end
end
