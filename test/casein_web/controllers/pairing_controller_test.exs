defmodule CaseinWeb.PairingControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.Workspace
  alias CaseinWeb.ChannelAuth

  defmodule OwnedSource do
    def get(id, _auth), do: {:ok, %Workspace{id: id, name: id, user: "owner", status: :running}}
  end

  setup do
    prev_source = Application.get_env(:casein, :workspace_source)
    prev_forward_auth = Application.get_env(:casein, :forward_auth)
    prev_canonical = Application.get_env(:casein, :canonical_public_origin)

    Application.put_env(:casein, :workspace_source, OwnedSource)
    Application.put_env(:casein, :forward_auth, true)
    Application.delete_env(:casein, :canonical_public_origin)

    on_exit(fn ->
      restore(:workspace_source, prev_source)
      restore(:forward_auth, prev_forward_auth)
      restore(:canonical_public_origin, prev_canonical)
    end)

    :ok
  end

  test "owner receives a short-lived workspace-scoped pairing token", %{conn: conn} do
    html =
      conn
      |> as("owner@example.com")
      |> get(~p"/pair/ws-1")
      |> html_response(200)

    code = pairing_code(html)
    {:ok, json} = Base.url_decode64(code, padding: false)
    payload = Jason.decode!(json)

    assert payload["workspace_id"] == "ws-1"
    assert payload["token_type"] == "mobile_pairing"
    assert payload["expires_in"] == ChannelAuth.pairing_token_max_age_seconds()
    assert payload["token_exchange_url"] == "http://www.example.com/api/device-links/exchange"
    assert payload["origin"]["id"] == Casein.Origin.id()
    assert payload["origin"]["base_url"] == "http://www.example.com"
    assert payload["resources"] == [%{"kind" => "workspace", "id" => "ws-1", "label" => "ws-1"}]
    assert "casein.session" in payload["capabilities"]

    assert {:ok, %{workspace_id: "ws-1", id: "owner"}} =
             ChannelAuth.verify_pairing_token(payload["token"])
  end

  test "any authenticated peer can mint a pairing token (flat peer model)", %{conn: conn} do
    conn = conn |> as("peer@example.com") |> get(~p"/pair/ws-1")

    assert html = html_response(conn, 200)
    assert html =~ "Pairing code"
  end

  test "managed origin redirects a legacy host before minting a pairing token", %{conn: conn} do
    Application.put_env(
      :casein,
      :canonical_public_origin,
      "https://casein.devbox.milcgroup.com"
    )

    conn =
      conn
      |> as("owner@example.com")
      |> get("https://devide.devbox.milcgroup.com/pair/ws-1")

    assert redirected_to(conn, 302) ==
             "https://casein.devbox.milcgroup.com/pair/ws-1"
  end

  test "managed origin embeds only the canonical host", %{conn: conn} do
    Application.put_env(
      :casein,
      :canonical_public_origin,
      "https://casein.devbox.milcgroup.com"
    )

    html =
      conn
      |> as("owner@example.com")
      |> get("https://casein.devbox.milcgroup.com/pair/ws-1")
      |> html_response(200)

    payload = html |> pairing_code() |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert payload["url"] == "https://casein.devbox.milcgroup.com"
    assert payload["origin"]["base_url"] == "https://casein.devbox.milcgroup.com"
    refute html =~ "devide.devbox"
  end

  defp pairing_code(html) do
    [_, code] = Regex.run(~r/<label>Pairing code<\/label><code>([^<]+)<\/code>/, html)
    code
  end

  defp as(conn, email), do: put_req_header(conn, "x-auth-request-email", email)

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)
end
