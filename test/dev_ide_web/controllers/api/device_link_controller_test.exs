defmodule DevIdeWeb.API.DeviceLinkControllerTest do
  use DevIdeWeb.ConnCase, async: false

  alias DevIDE.DeviceLinks
  alias DevIDE.Workspace
  alias DevIdeWeb.ChannelAuth

  defmodule OwnedSource do
    def get(id, _auth),
      do: {:ok, %Workspace{id: id, name: "Alpha", user: "owner", status: :running}}
  end

  setup do
    prev_source = Application.get_env(:dev_ide, :workspace_source)
    Application.put_env(:dev_ide, :workspace_source, OwnedSource)

    on_exit(fn -> restore(:workspace_source, prev_source) end)

    :ok
  end

  test "exchanges a short-lived pairing token for a persistent device link", %{conn: conn} do
    pairing_token =
      ChannelAuth.sign_pairing_token(%{id: "owner", email: "owner@example.com"}, "ws-1")

    conn =
      post(conn, ~p"/api/device-links/exchange", %{
        token: pairing_token,
        device_name: "Android tablet",
        platform: "android"
      })

    payload = json_response(conn, 200)
    device_token = payload["credential"]["token"]

    assert payload["origin"]["id"] == "dev_ide"
    assert payload["origin"]["base_url"] == "http://www.example.com"

    assert payload["origin"]["token_exchange_url"] ==
             "http://www.example.com/api/device-links/exchange"

    assert payload["credential"]["token_type"] == "device_link"
    assert is_binary(device_token)
    refute device_token == pairing_token
    assert payload["resources"] == [%{"kind" => "workspace", "id" => "ws-1", "label" => "Alpha"}]
    assert payload["workspace_id"] == "ws-1"
    assert "dev_ide.mobile_cards" in payload["capabilities"]

    assert {:ok, %{workspace_id: "ws-1", id: "owner"}} = DeviceLinks.verify_token(device_token)
  end

  test "rejects an invalid pairing token without API bearer auth", %{conn: conn} do
    conn = post(conn, ~p"/api/device-links/exchange", %{token: "bad-token"})

    assert json_response(conn, 401) == %{"error" => "invalid_pairing_token"}
  end

  test "rechecks resource ownership before issuing a token", %{conn: conn} do
    pairing_token =
      ChannelAuth.sign_pairing_token(%{id: "intruder", email: "intruder@example.com"}, "ws-1")

    conn = post(conn, ~p"/api/device-links/exchange", %{token: pairing_token})

    assert json_response(conn, 403) == %{"error" => "resource_forbidden"}
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)
end
