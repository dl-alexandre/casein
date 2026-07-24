defmodule Casein.Push.RuntimeConfigTest do
  use Casein.TestCase, async: false

  @push_envs ~w(
    DEV_IDE_PUSH_PROVIDER
    DEV_IDE_FCM_PROJECT_ID
    DEV_IDE_FCM_ACCESS_TOKEN
    DEV_IDE_FCM_SERVICE_ACCOUNT_JSON
    DEV_IDE_FCM_SERVICE_ACCOUNT_PATH
    DEV_IDE_FCM_TOKEN_URI
    DEV_IDE_APNS_TEAM_ID
    DEV_IDE_APNS_KEY_ID
    DEV_IDE_APNS_TOPIC
    DEV_IDE_APNS_PRIVATE_KEY
    DEV_IDE_APNS_PRIVATE_KEY_PATH
    DEV_IDE_APNS_ENV
  )

  setup do
    previous = Map.new(@push_envs, &{&1, System.get_env(&1)})
    Enum.each(@push_envs, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "FCM credentials select native platform routing by default" do
    System.put_env("DEV_IDE_FCM_PROJECT_ID", "demo-project")

    assert devide_runtime_config()[:push_provider] == Casein.Push.NativeProvider
  end

  test "APNs credentials select native platform routing by default" do
    System.put_env("DEV_IDE_APNS_TEAM_ID", "TEAM123456")
    System.put_env("DEV_IDE_APNS_KEY_ID", "KEY1234567")
    System.put_env("DEV_IDE_APNS_TOPIC", "com.example.devide_mob")
    System.put_env("DEV_IDE_APNS_PRIVATE_KEY_PATH", "/tmp/AuthKey_KEY1234567.p8")

    config = devide_runtime_config()

    assert config[:push_provider] == Casein.Push.NativeProvider

    assert config[Casein.Push.APNSProvider] == [
             team_id: "TEAM123456",
             key_id: "KEY1234567",
             topic: "com.example.devide_mob",
             private_key_path: "/tmp/AuthKey_KEY1234567.p8",
             environment: "sandbox"
           ]
  end

  test "explicit provider overrides are preserved" do
    System.put_env("DEV_IDE_PUSH_PROVIDER", "fcm")
    assert devide_runtime_config()[:push_provider] == Casein.Push.FCMProvider

    System.put_env("DEV_IDE_PUSH_PROVIDER", "apns")
    assert devide_runtime_config()[:push_provider] == Casein.Push.APNSProvider
  end

  defp devide_runtime_config do
    "config/runtime.exs"
    |> Config.Reader.read!(env: :dev)
    |> Keyword.fetch!(:casein)
  end
end
