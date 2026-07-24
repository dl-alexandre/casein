defmodule CaseinWeb.API.PreviewPaneControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.PreviewPanes

  @token "test-preview-pane-token"

  setup do
    prev = Application.get_env(:dev_ide, :api_token)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :api_token, @token)
    PreviewPanes.clear()

    root = Path.join(System.tmp_dir!(), "preview-pane-api-#{System.unique_integer([:positive])}")
    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)

    on_exit(fn ->
      PreviewPanes.clear()
      File.rm_rf(root)
      restore(:api_token, prev)
      restore(:workspaces_root, prev_root)
    end)

    {:ok, path: path}
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp auth_conn(conn, token \\ @token) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> then(fn c ->
      if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c
    end)
  end

  test "requires bearer token", %{conn: conn, path: path} do
    conn =
      post(conn, ~p"/api/preview/panes", %{
        "pane_id" => "%1",
        "url" => "http://localhost:5173/",
        "cwd" => path
      })

    assert conn.status == 401
  end

  test "POST creates registration with :PORT shorthand", %{conn: conn, path: path} do
    conn =
      conn
      |> auth_conn()
      |> post(~p"/api/preview/panes", %{
        "pane_id" => "%7",
        "url" => ":5173",
        "cwd" => path
      })

    assert %{
             "pane_id" => "%7",
             "url" => "http://localhost:5173/",
             "display_url" => display_url
           } = json_response(conn, 201)

    assert is_binary(display_url)
    assert PreviewPanes.get_by_pane("%7")
  end

  test "DELETE deregisters pane", %{conn: conn, path: path} do
    assert {:ok, _} =
             PreviewPanes.register(%{
               "pane_id" => "%8",
               "url" => "http://localhost:5173/",
               "cwd" => path
             })

    conn =
      conn
      |> auth_conn()
      |> delete(~p"/api/preview/panes/%8")

    assert %{"status" => "removed", "pane_id" => "%8"} = json_response(conn, 200)
    refute PreviewPanes.get_by_pane("%8")
  end
end
