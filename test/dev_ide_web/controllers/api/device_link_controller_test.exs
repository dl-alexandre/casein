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

    assert payload["origin"]["id"] == DevIDE.Origin.id()

    assert payload["origin"]["display_name"] ==
             DevIDE.Origin.display_name(payload["origin"]["base_url"])

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

  test "issues a token for any authenticated peer (flat peer model)", %{conn: conn} do
    pairing_token =
      ChannelAuth.sign_pairing_token(%{id: "peer", email: "peer@example.com"}, "ws-1")

    conn = post(conn, ~p"/api/device-links/exchange", %{token: pairing_token})

    payload = json_response(conn, 200)
    assert is_binary(payload["credential"]["token"])
    assert payload["workspace_id"] == "ws-1"
  end

  test "rotates a device link token and revokes the old one", %{conn: conn} do
    pairing_token =
      ChannelAuth.sign_pairing_token(%{id: "owner", email: "owner@example.com"}, "ws-1")

    old_token =
      conn
      |> post(~p"/api/device-links/exchange", %{token: pairing_token, platform: "ios"})
      |> json_response(200)
      |> get_in(["credential", "token"])

    payload =
      build_conn()
      |> post(~p"/api/device-links/rotate", %{token: old_token})
      |> json_response(200)

    new_token = payload["credential"]["token"]

    assert is_binary(new_token)
    refute new_token == old_token
    # New credential is valid and carries the original platform; old is revoked.
    assert {:ok, %{workspace_id: "ws-1", platform: "ios"}} = DeviceLinks.verify_token(new_token)
    assert {:error, :revoked} = DeviceLinks.verify_token(old_token)
  end

  test "rotate rejects an unknown token", %{conn: conn} do
    conn = post(conn, ~p"/api/device-links/rotate", %{token: "not-a-real-token"})
    assert json_response(conn, 401) == %{"error" => "invalid_token"}
  end

  test "revokes a device link token", %{conn: conn} do
    pairing_token =
      ChannelAuth.sign_pairing_token(%{id: "owner", email: "owner@example.com"}, "ws-1")

    token =
      conn
      |> post(~p"/api/device-links/exchange", %{token: pairing_token})
      |> json_response(200)
      |> get_in(["credential", "token"])

    revoke_response =
      build_conn()
      |> post(~p"/api/device-links/revoke", %{token: token})
      |> json_response(200)

    assert revoke_response == %{"status" => "revoked"}
    assert {:error, :revoked} = DeviceLinks.verify_token(token)
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)
end
