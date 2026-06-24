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

  defp seed_authorized_workspace! do
    root = Path.join(System.tmp_dir!(), "preview-proxy-#{System.unique_integer([:positive])}")
    path = Path.join([root, "dev", "ws"])
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    Application.put_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)
    Application.put_env(:dev_ide, :forward_auth, true)

    {root, "folder:" <> Base.url_encode64(path, padding: false)}
  end

  defp listen_once!(port, fun) do
    parent = self()
    {:ok, listen} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        request = read_http_request(socket)
        send(parent, {:preview_proxy_request, request})
        fun.(socket, request)
        :gen_tcp.close(socket)
      end)

    {listen, task}
  end

  defp read_http_request(socket, acc \\ "") do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
    acc = acc <> chunk

    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        expected = content_length(headers)

        if byte_size(body) >= expected do
          acc
        else
          read_http_request(socket, acc)
        end

      _ ->
        read_http_request(socket, acc)
    end
  end

  defp content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(name) == "content-length" do
            value |> String.trim() |> String.to_integer()
          end

        _ ->
          nil
      end
    end)
  end

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
    {root, workspace_id} = seed_authorized_workspace!()

    port = 5173

    {listen, task} =
      listen_once!(port, fn socket, _request ->
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nok")
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

  test "forwards non-GET requests and bodies for LiveView longpoll fallback", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()

    port = 5173

    {listen, task} =
      listen_once!(port, fn socket, _request ->
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n{}")
      end)

    ref = Process.monitor(task.pid)
    body = ~s({"topic":"lv:phx-test"})

    conn =
      conn
      |> put_req_header("x-auth-request-email", "dev@local")
      |> put_req_header("content-type", "application/json")
      |> post("/preview-proxy/#{workspace_id}/#{port}/live/longpoll?vsn=2.0.0", body)

    assert response(conn, 200) == "{}"
    assert_receive {:preview_proxy_request, request}
    assert request =~ "POST /live/longpoll?vsn=2.0.0 HTTP/1.1"
    assert request =~ "content-type: application/json"
    assert request =~ body
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}

    :gen_tcp.close(listen)
    File.rm_rf!(root)
  end

  test "forwards request cookies and preserves repeated set-cookie responses", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()

    port = 5173

    {listen, task} =
      listen_once!(port, fn socket, _request ->
        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: text/plain\r\n",
            "set-cookie: sid=one; Path=/; HttpOnly\r\n",
            "set-cookie: theme=dark; Path=/\r\n",
            "\r\n",
            "cookies"
          ])
      end)

    ref = Process.monitor(task.pid)

    conn =
      conn
      |> put_req_header("x-auth-request-email", "dev@local")
      |> put_req_header("cookie", "sid=old; theme=light")
      |> get("/preview-proxy/#{workspace_id}/#{port}/")

    assert response(conn, 200) == "cookies"
    assert_receive {:preview_proxy_request, request}
    assert request =~ "cookie: sid=old; theme=light"
    assert "sid=one; Path=/; HttpOnly" in get_resp_header(conn, "set-cookie")
    assert "theme=dark; Path=/" in get_resp_header(conn, "set-cookie")
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}

    :gen_tcp.close(listen)
    File.rm_rf!(root)
  end
end
