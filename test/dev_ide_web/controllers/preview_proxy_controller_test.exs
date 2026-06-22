defmodule DevIdeWeb.PreviewProxyControllerTest do
  use DevIdeWeb.ConnCase, async: false

  setup do
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_source = Application.get_env(:dev_ide, :workspace_source)
    prev_forward_auth = Application.get_env(:dev_ide, :forward_auth)

    on_exit(fn ->
      restore(:workspaces_root, prev_root)
      restore(:workspace_source, prev_source)
      restore(:forward_auth, prev_forward_auth)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  # Port validation happens before any workspace/authorization work, so these
  # exercise the route + first guard without touching the workspace source.
  test "rejects a non-numeric port with 400", %{conn: conn} do
    conn = get(conn, "/preview-proxy/ws-1/not-a-port/")
    assert response(conn, 400)
  end

  test "rejects an out-of-range port with 400", %{conn: conn} do
    conn = get(conn, "/preview-proxy/ws-1/99999/")
    assert response(conn, 400)
  end

  test "rejects port zero with 400", %{conn: conn} do
    conn = get(conn, "/preview-proxy/ws-1/0/")
    assert response(conn, 400)
  end

  test "accepts an authorized workspace dev port", %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "preview-proxy-#{System.unique_integer([:positive])}")
    path = Path.join([root, "dev", "ws"])
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    Application.put_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)
    Application.put_env(:dev_ide, :forward_auth, true)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)

    port = 5173
    {:ok, listen} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nok")
        :gen_tcp.close(socket)
      end)

    ref = Process.monitor(task.pid)

    conn =
      conn
      |> put_req_header("x-auth-request-email", "dev@local")
      |> get("/preview-proxy/#{workspace_id}/#{port}/")

    assert response(conn, 200) == "ok"
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}

    :gen_tcp.close(listen)
    File.rm_rf!(root)
  end
end
