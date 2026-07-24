defmodule CaseinWeb.PreviewProxyControllerTest do
  use CaseinWeb.ConnCase, async: false

  setup do
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_source = Application.get_env(:casein, :workspace_source)
    prev_forward_auth = Application.get_env(:casein, :forward_auth)
    prev_hmr = Application.get_env(:casein, :preview_proxy_hmr)
    Casein.PreviewPanes.clear()

    on_exit(fn ->
      Casein.PreviewPanes.clear()
      restore(:workspaces_root, prev_root)
      restore(:workspace_source, prev_source)
      restore(:forward_auth, prev_forward_auth)
      restore(:preview_proxy_hmr, prev_hmr)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  @ws_echo_ports [8080, 9000, 3000, 5173, 4173]

  defp start_ws_echo_upstream! do
    Enum.find_value(@ws_echo_ports, fn port ->
      # Probe first: on a shared host (the self-hosted gate runner) an allowed
      # dev port may already be held by a live workload. Bandit.start_link links,
      # so a bind failure arrives as a linked EXIT that kills the test before the
      # fallback loop reaches a free port — skip un-bindable ports up front.
      with true <- port_bindable?(port),
           {:ok, pid} <-
             Bandit.start_link(
               plug: {CaseinWeb.PreviewProxyControllerTest.EchoPlug, []},
               scheme: :http,
               ip: {127, 0, 0, 1},
               port: port
             ) do
        Process.put({:ws_echo_upstream, port}, pid)
        port
      else
        _ -> nil
      end
    end) || flunk("no allowed dev port free to bind the upstream echo server")
  end

  defp port_bindable?(port) do
    case :gen_tcp.listen(port, [:inet, {:ip, {127, 0, 0, 1}}, {:reuseaddr, false}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp stop_ws_echo_upstream!(port) do
    case Process.get({:ws_echo_upstream, port}) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)

      _ ->
        :ok
    end
  end

  defp ws_upgrade_conn(conn, workspace_id, port) do
    conn =
      if Enum.any?(conn.req_headers, fn {k, _} -> String.downcase(k) == "host" end) do
        conn
      else
        %{conn | req_headers: [{"host", conn.host} | conn.req_headers]}
      end

    conn
    |> put_req_header("x-auth-request-email", "dev@local")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("connection", "Upgrade")
    |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    |> put_req_header("sec-websocket-version", "13")
    |> get("/preview-proxy/#{workspace_id}/#{port}/live/websocket?vsn=2.0.0")
  end

  defp seed_authorized_workspace! do
    root = Path.join(System.tmp_dir!(), "preview-proxy-#{System.unique_integer([:positive])}")
    path = Path.join([root, "dev", "ws"])
    File.mkdir_p!(path)
    Application.put_env(:casein, :workspaces_root, root)
    Application.put_env(:casein, :workspace_source, Casein.WorkspaceSource.Local)
    Application.put_env(:casein, :forward_auth, true)

    {root, "folder:" <> Base.url_encode64(path, padding: false)}
  end

  defp listen_once!(fun), do: listen_once!(0, fun)

  defp listen_once!(port, fun) do
    parent = self()
    {:ok, listen} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_address, bound_port}} = :inet.sockname(listen)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        request = read_http_request(socket)
        send(parent, {:preview_proxy_request, request})
        fun.(socket, request)
        :gen_tcp.close(socket)
      end)

    {listen, bound_port, task}
  end

  defp register_preview_port!(workspace_id, port) do
    pane_id = "%preview-proxy-#{System.unique_integer([:positive])}"
    url = "http://127.0.0.1:#{port}/"

    assert {:ok, _registration} =
             Casein.PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => url,
               "workspace_id" => workspace_id
             })

    port
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

    {listen, port, task} =
      listen_once!(fn socket, _request ->
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nok")
      end)

    register_preview_port!(workspace_id, port)
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

  test "rejects an unowned common dev port but accepts a registered workspace port",
       %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()

    rejected_conn =
      conn
      |> put_req_header("x-auth-request-email", "dev@local")
      |> get("/preview-proxy/#{workspace_id}/4000/")

    assert response(rejected_conn, 403) == "Port not allowed for this workspace"

    {listen, port, task} =
      listen_once!(fn socket, _request ->
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nowned")
      end)

    register_preview_port!(workspace_id, port)
    ref = Process.monitor(task.pid)

    allowed_conn =
      build_conn()
      |> put_req_header("x-auth-request-email", "dev@local")
      |> get("/preview-proxy/#{workspace_id}/#{port}/")

    assert response(allowed_conn, 200) == "owned"
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}

    :gen_tcp.close(listen)
    File.rm_rf!(root)
  end

  test "forwards non-GET requests and bodies for LiveView longpoll fallback", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()

    {listen, port, task} =
      listen_once!(fn socket, _request ->
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n{}")
      end)

    register_preview_port!(workspace_id, port)
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

  test "forwards Authorization headers unchanged to the upstream", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()

    {listen, port, task} =
      listen_once!(fn socket, _request ->
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nok")
      end)

    register_preview_port!(workspace_id, port)
    ref = Process.monitor(task.pid)

    conn =
      conn
      |> put_req_header("x-auth-request-email", "dev@local")
      |> put_req_header("authorization", "Bearer upstream-app-token")
      |> get("/preview-proxy/#{workspace_id}/#{port}/")

    assert response(conn, 200) == "ok"
    assert_receive {:preview_proxy_request, request}
    assert request =~ "authorization: Bearer upstream-app-token"
    refute request =~ "[FILTERED]"
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}

    :gen_tcp.close(listen)
    File.rm_rf!(root)
  end

  test "forwards request cookies and preserves repeated set-cookie responses", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()

    {listen, port, task} =
      listen_once!(fn socket, _request ->
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

    register_preview_port!(workspace_id, port)
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

  test "serves a friendly 502 page when the upstream is not answering", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()

    # Accept the connection but close without an HTTP response → Req errors.
    {listen, port, task} = listen_once!(fn _socket, _request -> :ok end)
    register_preview_port!(workspace_id, port)
    ref = Process.monitor(task.pid)

    conn =
      conn
      |> put_req_header("x-auth-request-email", "dev@local")
      |> get("/preview-proxy/#{workspace_id}/#{port}/")

    assert response(conn, 502) =~ "Nothing is listening on port #{port}"
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    :gen_tcp.close(listen)
    File.rm_rf!(root)
  end

  test "forwards PUT/PATCH/DELETE/HEAD methods to the upstream", %{conn: _conn} do
    # OPTIONS is rejected by ForwardAuth (405) so a client-supplied
    # X-Auth-Request-Email cannot spoof identity on the preview-proxy catch-all.
    for method <- [:put, :patch, :delete, :head] do
      {root, workspace_id} = seed_authorized_workspace!()

      {listen, port, task} =
        listen_once!(fn socket, _request ->
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nok")
        end)

      register_preview_port!(workspace_id, port)
      ref = Process.monitor(task.pid)

      conn =
        build_conn()
        |> put_req_header("x-auth-request-email", "dev@local")
        |> put_req_header("content-type", "application/octet-stream")

      path = "/preview-proxy/#{workspace_id}/#{port}/"

      conn =
        case method do
          :put -> put(conn, path, "body")
          :patch -> patch(conn, path, "body")
          :delete -> delete(conn, path)
          :head -> head(conn, path)
        end

      assert conn.status == 200
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

      :gen_tcp.close(listen)
      File.rm_rf!(root)
    end
  end

  test "rewrites CSS and JavaScript bodies served through the proxy", %{conn: _conn} do
    cases = [
      {"text/css", ".a{background:url(/img/x.png)}", "url(/preview-proxy/"},
      {"application/javascript", ~s|new LiveSocket("/live")|, "/preview-proxy/"}
    ]

    for {content_type, body, expected} <- cases do
      {root, workspace_id} = seed_authorized_workspace!()

      {listen, port, task} =
        listen_once!(fn socket, _request ->
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: #{content_type}\r\n\r\n#{body}")
        end)

      register_preview_port!(workspace_id, port)
      ref = Process.monitor(task.pid)

      conn =
        build_conn()
        |> put_req_header("x-auth-request-email", "dev@local")
        |> get("/preview-proxy/#{workspace_id}/#{port}/asset")

      assert response(conn, 200) =~ expected
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

      :gen_tcp.close(listen)
      File.rm_rf!(root)
    end
  end

  test "passes through a response that carries no content-type", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()

    {listen, port, task} =
      listen_once!(fn socket, _request ->
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\n\r\nplain")
      end)

    register_preview_port!(workspace_id, port)
    ref = Process.monitor(task.pid)

    conn =
      conn
      |> put_req_header("x-auth-request-email", "dev@local")
      |> get("/preview-proxy/#{workspace_id}/#{port}/")

    assert response(conn, 200) == "plain"
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    :gen_tcp.close(listen)
    File.rm_rf!(root)
  end

  test "logs Phoenix transport requests routed through the proxy", %{conn: conn} do
    prev_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: prev_level) end)

    {root, workspace_id} = seed_authorized_workspace!()

    {listen, port, task} =
      listen_once!(fn socket, _request ->
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nok")
      end)

    register_preview_port!(workspace_id, port)
    ref = Process.monitor(task.pid)

    conn =
      conn
      |> put_req_header("x-auth-request-email", "dev@local")
      |> get("/preview-proxy/#{workspace_id}/#{port}/live")

    assert response(conn, 200) == "ok"
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    :gen_tcp.close(listen)
    File.rm_rf!(root)
  end

  test "accepts a websocket upgrade with 101 and writes no session cookie when HMR tunneling is enabled",
       %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()
    Application.put_env(:casein, :preview_proxy_hmr, enabled: true)

    upstream_port = start_ws_echo_upstream!()
    on_exit(fn -> stop_ws_echo_upstream!(upstream_port) end)
    register_preview_port!(workspace_id, upstream_port)

    conn = ws_upgrade_conn(conn, workspace_id, upstream_port)

    assert conn.status == 101
    assert conn.state == :upgraded
    assert get_resp_header(conn, "set-cookie") == []
    assert conn.private[:plug_session_info] == :ignore

    File.rm_rf!(root)
  end

  test "refuses a websocket upgrade when HMR tunneling is disabled", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()
    Application.put_env(:casein, :preview_proxy_hmr, enabled: false)
    register_preview_port!(workspace_id, 5173)

    conn = ws_upgrade_conn(conn, workspace_id, 5173)

    assert response(conn, 426)
    File.rm_rf!(root)
  end

  test "rejects a websocket upgrade past the per-workspace cap", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()
    Application.put_env(:casein, :preview_proxy_hmr, enabled: true, max_per_workspace: 1)
    register_preview_port!(workspace_id, 5173)

    # Occupy the single slot with a live registration, mirroring an open tunnel.
    parent = self()

    {:ok, holder} =
      Task.start(fn ->
        Registry.register(CaseinWeb.PreviewProxy.WebSocketRegistry, workspace_id, 5173)
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered

    conn = ws_upgrade_conn(conn, workspace_id, 5173)

    assert response(conn, 429)

    Process.exit(holder, :kill)
    File.rm_rf!(root)
  end

  test "a websocket upgrade from an unauthenticated viewer is rejected", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()
    Application.put_env(:casein, :preview_proxy_hmr, enabled: true)

    # No x-auth-request-email header => ForwardAuth blocks before the upgrade,
    # so the tunnel never reaches the WS branch.
    conn =
      conn
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("connection", "Upgrade")
      |> get("/preview-proxy/#{workspace_id}/5173/live/websocket")

    assert response(conn, 401)
    File.rm_rf!(root)
  end

  test "a websocket upgrade to a disallowed port is rejected", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()
    Application.put_env(:casein, :preview_proxy_hmr, enabled: true)

    # 6000 is neither declared/detected nor a registered preview port.
    conn = ws_upgrade_conn(conn, workspace_id, 6000)

    assert response(conn, 403)
    File.rm_rf!(root)
  end

  test "injects HMR assets into proxied HTML when the tunnel is enabled", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()
    Application.put_env(:casein, :preview_proxy_hmr, enabled: true)

    {listen, port, task} =
      listen_once!(fn socket, _request ->
        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\n\r\n<html><head></head><body>hi</body></html>"
          )
      end)

    register_preview_port!(workspace_id, port)
    ref = Process.monitor(task.pid)

    conn =
      conn
      |> put_req_header("x-auth-request-email", "dev@local")
      |> get("/preview-proxy/#{workspace_id}/#{port}/")

    body = response(conn, 200)
    assert body =~ ~s(<script type="importmap")
    assert body =~ "window.WebSocket = Patched"
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}

    :gen_tcp.close(listen)
    File.rm_rf!(root)
  end

  test "leaves proxied HTML free of HMR assets when the tunnel is disabled", %{conn: conn} do
    {root, workspace_id} = seed_authorized_workspace!()
    Application.put_env(:casein, :preview_proxy_hmr, enabled: false)

    {listen, port, task} =
      listen_once!(fn socket, _request ->
        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\n\r\n<html><head></head><body>hi</body></html>"
          )
      end)

    register_preview_port!(workspace_id, port)
    ref = Process.monitor(task.pid)

    conn =
      conn
      |> put_req_header("x-auth-request-email", "dev@local")
      |> get("/preview-proxy/#{workspace_id}/#{port}/")

    body = response(conn, 200)
    refute body =~ "importmap"
    # Base injection still happens; only the HMR layer is gated off.
    assert body =~ ~s(<base href="/preview-proxy/#{workspace_id}/#{port}/")
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}

    :gen_tcp.close(listen)
    File.rm_rf!(root)
  end
end

defmodule CaseinWeb.PreviewProxyControllerTest.EchoWS do
  @moduledoc false
  @behaviour WebSock

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}

  @impl true
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end

defmodule CaseinWeb.PreviewProxyControllerTest.EchoPlug do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts),
    do:
      conn
      |> WebSockAdapter.upgrade(CaseinWeb.PreviewProxyControllerTest.EchoWS, [], [])
      |> halt()
end
