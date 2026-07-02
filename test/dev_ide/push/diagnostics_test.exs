defmodule DevIDE.Push.DiagnosticsTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Push.{APNSProvider, Diagnostics, FCMProvider, FCMToken}

  setup do
    prev_provider = Application.get_env(:dev_ide, :push_provider)
    prev_fcm = Application.get_env(:dev_ide, FCMProvider)
    prev_fcm_token = Application.get_env(:dev_ide, FCMToken)
    prev_apns = Application.get_env(:dev_ide, APNSProvider)

    on_exit(fn ->
      restore_env(:push_provider, prev_provider)
      restore_module_env(FCMProvider, prev_fcm)
      restore_module_env(FCMToken, prev_fcm_token)
      restore_module_env(APNSProvider, prev_apns)
    end)

    :ok
  end

  test "reports default log provider as not deliverable" do
    Application.put_env(:dev_ide, :push_provider, DevIDE.Push.LogProvider)

    report = Diagnostics.report(["android"])

    assert report.provider == DevIDE.Push.LogProvider
    assert report.ready? == false

    assert [%{platform: "android", status: :not_ready, reason: :push_provider_unconfigured}] =
             report.platforms
  end

  test "reports native provider ready when APNs and FCM are configured" do
    Application.put_env(:dev_ide, :push_provider, DevIDE.Push.NativeProvider)

    Application.put_env(:dev_ide, FCMProvider,
      project_id: "demo-project",
      access_token_fun: {FCMToken, :access_token, []}
    )

    Application.put_env(:dev_ide, FCMToken, access_token: "ya29.test-token")

    Application.put_env(:dev_ide, APNSProvider,
      team_id: "TEAM123456",
      key_id: "KEY1234567",
      topic: "com.example.devide_mob",
      private_key: private_key_pem()
    )

    report = Diagnostics.report(["android", "ios"])

    assert report.provider == DevIDE.Push.NativeProvider
    assert report.ready? == true
    assert Enum.map(report.platforms, & &1.status) == [:ready, :ready]
  end

  defp private_key_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)

  defp restore_module_env(module, nil), do: Application.delete_env(:dev_ide, module)
  defp restore_module_env(module, value), do: Application.put_env(:dev_ide, module, value)
end
