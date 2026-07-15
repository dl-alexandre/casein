defmodule DevIdeWeb.API.DrainControllerTest do
  use DevIdeWeb.ConnCase, async: false

  alias DevIDE.Deployment.Drain

  @token "test-token"

  setup %{conn: conn} do
    Drain.reset_for_test!()

    prev_token = Application.get_env(:dev_ide, :api_token)
    Application.put_env(:dev_ide, :api_token, @token)

    on_exit(fn ->
      Drain.reset_for_test!()

      if prev_token,
        do: Application.put_env(:dev_ide, :api_token, prev_token),
        else: Application.delete_env(:dev_ide, :api_token)
    end)

    {:ok, conn: conn}
  end

  test "returns 401 without bearer token", %{conn: conn} do
    conn = post(conn, ~p"/api/drain", %{})
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "starts drain and returns ok", %{conn: conn} do
    conn = drain_request(conn, 2)
    assert json_response(conn, 200) == %{"ok" => true}
    assert Drain.draining?()
  end

  test "returns 409 when already draining", %{conn: conn} do
    assert json_response(drain_request(conn, 1), 200) == %{"ok" => true}

    conn = drain_request(conn, 5)
    assert json_response(conn, 409) == %{"error" => "already_draining"}
  end

  test "parses commits_behind from string params", %{conn: conn} do
    :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, "deploy:updates")
    conn = drain_request(conn, "3")
    assert json_response(conn, 200) == %{"ok" => true}
    assert_receive {:update_available, _version, 3}
  end

  defp drain_request(conn, commits_behind) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> post(~p"/api/drain", %{"commits_behind" => commits_behind})
  end
end
