defmodule CaseinMob.DeviceLinkTest do
  use ExUnit.Case, async: false

  alias CaseinMob.DeviceLink

  setup do
    previous = Application.get_env(:casein_mob, :device_link_exchange_client)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:casein_mob, :device_link_exchange_client, previous),
        else: Application.delete_env(:casein_mob, :device_link_exchange_client)
    end)

    :ok
  end

  test "accepts HTTPS and private-network HTTP pairing origins" do
    for url <- [
          "https://casein.devbox.milcgroup.com",
          "http://DairyBookPro.local:41111",
          "http://10.0.0.8:41111",
          "http://172.16.0.8:41111",
          "http://192.168.1.72:41111"
        ] do
      assert {:ok, %{url: ^url, token: "token", workspace_id: "workspace"}} =
               DeviceLink.pair(%{
                 url: url,
                 token: "token",
                 workspace_id: "workspace"
               })
    end
  end

  test "rejects cleartext public and malformed pairing origins" do
    for url <- [
          "http://example.com",
          "http://172.32.0.8",
          "http://192.169.1.72",
          "ftp://192.168.1.72",
          "not a url"
        ] do
      assert {:error, :invalid_payload} =
               DeviceLink.pair(%{
                 url: url,
                 token: "token",
                 workspace_id: "workspace"
               })
    end
  end

  test "rejects a cleartext public token exchange endpoint" do
    assert {:error, :insecure_transport} =
             DeviceLink.pair(%{
               url: "https://casein.example",
               token: "bootstrap",
               workspace_id: "workspace",
               token_exchange_url: "http://example.com/api/device-links/exchange"
             })
  end

  test "preserves the server origin descriptor without treating URL as identity" do
    assert {:ok, pairing} =
             DeviceLink.pair(%{
               url: "https://new-host.test",
               token: "token",
               workspace_id: "workspace",
               origin: %{
                 id: "installation-1",
                 display_name: "Local Mac",
                 base_url: "https://new-host.test"
               }
             })

    assert pairing.origin_id == "installation-1"
    assert pairing.display_name == "Local Mac"
  end

  test "rejects a descriptor whose base URL differs from the scanned origin" do
    assert {:error, :origin_mismatch} =
             DeviceLink.pair(%{
               url: "https://old-host.test",
               token: "token",
               workspace_id: "workspace",
               origin: %{
                 id: "installation-1",
                 display_name: "Devbox",
                 base_url: "https://new-host.test"
               }
             })
  end

  test "rejects a cross-origin token exchange endpoint before any request" do
    Application.put_env(:casein_mob, :device_link_exchange_client, fn _url, _request ->
      flunk("cross-origin exchange client must not be called")
    end)

    assert {:error, :origin_mismatch} =
             DeviceLink.pair(%{
               url: "https://casein.devbox.milcgroup.com",
               token: "bootstrap",
               workspace_id: "workspace",
               origin: %{
                 id: "installation-1",
                 base_url: "https://casein.devbox.milcgroup.com"
               },
               token_exchange_url: "https://devide.devbox.milcgroup.com/api/device-links/exchange"
             })
  end

  test "stable descriptors fail closed when exchange is unavailable" do
    Application.put_env(:casein_mob, :device_link_exchange_client, fn _url, _request ->
      {:error, :unavailable}
    end)

    assert {:error, :unavailable} =
             DeviceLink.pair(stable_exchange_payload())
  end

  test "stable descriptors reject a response origin, resource, or URL mismatch" do
    for pairing <- [
          %{
            url: "https://other.test",
            token: "durable",
            workspace_id: "workspace",
            origin_id: "installation-1",
            display_name: "Devbox"
          },
          %{
            url: "https://casein.devbox.milcgroup.com",
            token: "durable",
            workspace_id: "other-workspace",
            origin_id: "installation-1",
            display_name: "Devbox"
          },
          %{
            url: "https://casein.devbox.milcgroup.com",
            token: "durable",
            workspace_id: "workspace",
            origin_id: "forged-installation",
            display_name: "Devbox"
          }
        ] do
      Application.put_env(:casein_mob, :device_link_exchange_client, fn _url, _request ->
        {:ok, pairing}
      end)

      assert {:error, reason} = DeviceLink.pair(stable_exchange_payload())
      assert reason in [:origin_mismatch, :resource_mismatch]
    end
  end

  test "legacy payloads retain compatibility fallback when no stable descriptor exists" do
    Application.put_env(:casein_mob, :device_link_exchange_client, fn _url, _request ->
      {:error, :not_found}
    end)

    assert {:ok, %{token: "bootstrap", workspace_id: "workspace"}} =
             DeviceLink.pair(%{
               url: "https://legacy.example",
               token: "bootstrap",
               workspace_id: "workspace",
               token_exchange_url: "https://legacy.example/api/device-links/exchange"
             })
  end

  defp stable_exchange_payload do
    %{
      url: "https://casein.devbox.milcgroup.com",
      token: "bootstrap",
      workspace_id: "workspace",
      origin: %{
        id: "installation-1",
        display_name: "Devbox",
        base_url: "https://casein.devbox.milcgroup.com"
      },
      token_exchange_url: "https://casein.devbox.milcgroup.com/api/device-links/exchange"
    }
  end
end
