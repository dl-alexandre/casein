defmodule CaseinWeb.PairingControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.DeviceLinks
  alias Casein.DeviceLinks.PairingHandle
  alias Casein.Repo
  alias Casein.Workspace

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

  test "owner receives a camera-friendly compact single-use pairing handle", %{conn: conn} do
    conn =
      conn
      |> as("owner@example.com")
      |> get(~p"/pair/ws-1")

    assert get_resp_header(conn, "cache-control") == ["no-store, max-age=0"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
    html = html_response(conn, 200)

    code = pairing_code(html)
    assert byte_size(code) <= 220
    [_, modules] = Regex.run(~r/viewBox="0 0 ([0-9]+) \1"/, html)
    assert String.to_integer(modules) <= 49

    encoded = String.replace_prefix(code, "casein://pair/", "")
    {:ok, json} = Base.url_decode64(encoded, padding: false)
    payload = Jason.decode!(json)

    assert payload == %{
             "v" => 1,
             "o" => "http://www.example.com",
             "h" => payload["h"]
           }

    assert byte_size(payload["h"]) == 43
    assert {:ok, entropy} = Base.url_decode64(payload["h"], padding: false)
    assert byte_size(entropy) == 32
    refute html =~ "mobile_pairing"
    refute html =~ "casein.mobile_cards"
    refute html =~ "token_exchange_url"

    pending = Repo.get_by!(PairingHandle, handle_hash: DeviceLinks.token_hash(payload["h"]))
    assert pending.resource_id == "ws-1"
    assert pending.subject_id == "owner"
    assert pending.audience == "casein_mobile"
    assert pending.origin_base_url == "http://www.example.com"
    assert "casein.session" in pending.capabilities
    refute inspect(pending) =~ payload["h"]
  end

  test "any authenticated peer can mint a pairing handle (flat peer model)", %{conn: conn} do
    conn = conn |> as("peer@example.com") |> get(~p"/pair/ws-1")

    assert html = html_response(conn, 200)
    assert html =~ "Compact pairing code"
  end

  test "managed origin redirects a legacy host before minting a pairing handle", %{conn: conn} do
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

    payload = decode_pairing_code(html)
    assert payload["o"] == "https://casein.devbox.milcgroup.com"
    refute html =~ "devide.devbox"
  end

  defp pairing_code(html) do
    [_, code] = Regex.run(~r/<label>Compact pairing code<\/label><code>([^<]+)<\/code>/, html)
    code
  end

  defp decode_pairing_code(html) do
    encoded = html |> pairing_code() |> String.replace_prefix("casein://pair/", "")
    encoded |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp as(conn, email), do: put_req_header(conn, "x-auth-request-email", email)

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)
end
