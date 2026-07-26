defmodule CaseinMob.DeviceLinkTest do
  use ExUnit.Case, async: true

  alias CaseinMob.DeviceLink

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
               url: "https://old-host.test",
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
end
