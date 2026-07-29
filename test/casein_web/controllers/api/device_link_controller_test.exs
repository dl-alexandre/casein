defmodule CaseinWeb.API.DeviceLinkControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.DeviceLinks
  alias Casein.Workspace
  alias CaseinWeb.ChannelAuth

  defmodule OwnedSource do
    def get(id, _auth),
      do: {:ok, %Workspace{id: id, name: "Alpha", user: "owner", status: :running}}
  end

  setup do
    prev_source = Application.get_env(:casein, :workspace_source)
    prev_canonical = Application.get_env(:casein, :canonical_public_origin)
    Application.put_env(:casein, :workspace_source, OwnedSource)
    Application.delete_env(:casein, :canonical_public_origin)

    on_exit(fn ->
      restore(:workspace_source, prev_source)
      restore(:canonical_public_origin, prev_canonical)
    end)

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

    assert payload["origin"]["id"] == Casein.Origin.id()

    assert payload["origin"]["display_name"] ==
             Casein.Origin.display_name(payload["origin"]["base_url"])

    assert payload["origin"]["base_url"] == "http://www.example.com"

    assert payload["origin"]["token_exchange_url"] ==
             "http://www.example.com/api/device-links/exchange"

    assert payload["credential"]["token_type"] == "device_link"
    assert is_binary(device_token)
    refute device_token == pairing_token
    assert payload["resources"] == [%{"kind" => "workspace", "id" => "ws-1", "label" => "Alpha"}]
    assert payload["workspace_id"] == "ws-1"
    assert "casein.mobile_cards" in payload["capabilities"]

    assert {:ok, %{workspace_id: "ws-1", id: "owner"}} = DeviceLinks.verify_token(device_token)
  end

  test "exchanges a compact handle once and rejects replay", %{conn: conn} do
    {:ok, pending} =
      DeviceLinks.issue_pairing_handle(
        %{id: "owner", email: "owner@example.com", role: :owner},
        "ws-1",
        "http://www.example.com"
      )

    request = %{
      handle: pending.handle,
      origin: "http://www.example.com",
      audience: "casein_mobile",
      device_name: "Android tablet",
      platform: "android"
    }

    payload =
      conn
      |> post(~p"/api/device-links/exchange", request)
      |> json_response(200)

    assert payload["workspace_id"] == "ws-1"
    assert payload["origin"]["base_url"] == "http://www.example.com"
    assert {:ok, %{workspace_id: "ws-1"}} = DeviceLinks.verify_token(payload["token"])

    replay =
      build_conn()
      |> post(~p"/api/device-links/exchange", request)

    assert json_response(replay, 409) == %{"error" => "pairing_handle_already_used"}
  end

  test "compact exchange returns generic errors for invalid or expired handles", %{conn: conn} do
    invalid =
      post(conn, ~p"/api/device-links/exchange", %{
        handle: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        origin: "http://www.example.com",
        audience: "casein_mobile"
      })

    assert json_response(invalid, 401) == %{"error" => "invalid_pairing_handle"}

    {:ok, pending} =
      DeviceLinks.issue_pairing_handle(
        %{id: "owner", email: "owner@example.com", role: :owner},
        "ws-1",
        "http://www.example.com"
      )

    Casein.DeviceLinks.PairingHandle
    |> Casein.Repo.get_by!(handle_hash: DeviceLinks.token_hash(pending.handle))
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Casein.Repo.update!()

    expired =
      build_conn()
      |> post(~p"/api/device-links/exchange", %{
        handle: pending.handle,
        origin: "http://www.example.com",
        audience: "casein_mobile"
      })

    assert json_response(expired, 410) == %{"error" => "pairing_handle_expired"}
  end

  test "rejects an invalid pairing token without API bearer auth", %{conn: conn} do
    conn = post(conn, ~p"/api/device-links/exchange", %{token: "bad-token"})

    assert json_response(conn, 401) == %{"error" => "invalid_pairing_token"}
  end

  test "managed origin rejects exchange, rotation, and revocation on a legacy host", %{
    conn: conn
  } do
    Application.put_env(
      :casein,
      :canonical_public_origin,
      "https://casein.devbox.milcgroup.com"
    )

    pairing_token =
      ChannelAuth.sign_pairing_token(%{id: "owner", email: "owner@example.com"}, "ws-1")

    legacy_conn = fn ->
      build_conn()
      |> Map.put(:scheme, :https)
      |> Map.put(:host, "devide.devbox.milcgroup.com")
      |> Map.put(:port, 443)
    end

    assert legacy_conn.()
           |> post(~p"/api/device-links/exchange", %{token: pairing_token})
           |> json_response(409) == %{"error" => "origin_mismatch"}

    assert legacy_conn.()
           |> post(~p"/api/device-links/rotate", %{token: "credential"})
           |> json_response(409) == %{"error" => "origin_mismatch"}

    assert conn
           |> Map.put(:scheme, :https)
           |> Map.put(:host, "devide.devbox.milcgroup.com")
           |> Map.put(:port, 443)
           |> post(~p"/api/device-links/revoke", %{token: "credential"})
           |> json_response(409) == %{"error" => "origin_mismatch"}
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

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)
end
