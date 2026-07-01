defmodule DevIdeWeb.PairingControllerTest do
  use DevIdeWeb.ConnCase, async: false

  alias DevIDE.Workspace
  alias DevIdeWeb.ChannelAuth

  defmodule OwnedSource do
    def get(id, _auth), do: {:ok, %Workspace{id: id, name: id, user: "owner", status: :running}}
  end

  setup do
    prev_source = Application.get_env(:dev_ide, :workspace_source)
    prev_forward_auth = Application.get_env(:dev_ide, :forward_auth)

    Application.put_env(:dev_ide, :workspace_source, OwnedSource)
    Application.put_env(:dev_ide, :forward_auth, true)

    on_exit(fn ->
      restore(:workspace_source, prev_source)
      restore(:forward_auth, prev_forward_auth)
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
    assert payload["origin"]["id"] == "dev_ide"
    assert payload["origin"]["base_url"] == "http://www.example.com"
    assert payload["resources"] == [%{"kind" => "workspace", "id" => "ws-1", "label" => "ws-1"}]
    assert "dev_ide.session" in payload["capabilities"]

    assert {:ok, %{workspace_id: "ws-1", id: "owner"}} =
             ChannelAuth.verify_pairing_token(payload["token"])
  end

  test "non-owner cannot mint a pairing token", %{conn: conn} do
    conn = conn |> as("intruder@example.com") |> get(~p"/pair/ws-1")

    assert html_response(conn, 403) =~ "not allowed"
  end

  defp pairing_code(html) do
    [_, code] = Regex.run(~r/<label>Pairing code<\/label><code>([^<]+)<\/code>/, html)
    code
  end

  defp as(conn, email), do: put_req_header(conn, "x-auth-request-email", email)

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)
end
