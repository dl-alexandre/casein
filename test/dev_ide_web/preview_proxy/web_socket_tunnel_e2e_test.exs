defmodule DevIdeWeb.PreviewProxy.WebSocketTunnelE2ETest do
  @moduledoc """
  End-to-end proof that a WebSocket survives the *whole* stack: a real HTTP
  listener for `DevIdeWeb.Endpoint`, the `:preview_proxy` pipeline + auth gate,
  the controller's `WebSockAdapter.upgrade` dispatch, the `WebSocketBridge`, and
  a real upstream dev-server socket. A `Mint.WebSocket` client drives it over a
  real TCP connection and asserts a frame round-trips browser→DevIDE→upstream→back.

  This closes the one seam the unit tests can't cross (route → upgrade → bridge
  over a real socket); the headed "edit file → HMR update in the browser" loop
  still has to be eyeballed against a real Vite app.
  """
  use DevIDE.TestCase, async: false

  # Loopback dev ports that pass `Url.port_allowed?/2`; we bind the first free one
  # since this box is busy and fixed ports collide.
  @candidate_ports [8080, 9000, 3000, 5173]

  defmodule EchoWS do
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

  defmodule EchoPlug do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts
    def call(conn, _opts), do: conn |> WebSockAdapter.upgrade(EchoWS, [], []) |> halt()
  end

  setup do
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_source = Application.get_env(:dev_ide, :workspace_source)
    prev_forward_auth = Application.get_env(:dev_ide, :forward_auth)
    prev_hmr = Application.get_env(:dev_ide, :preview_proxy_hmr)

    root = Path.join(System.tmp_dir!(), "ws-e2e-#{System.unique_integer([:positive])}")
    path = Path.join([root, "dev", "ws"])
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    Application.put_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)
    Application.put_env(:dev_ide, :forward_auth, true)
    Application.put_env(:dev_ide, :preview_proxy_hmr, enabled: true)

    on_exit(fn ->
      File.rm_rf!(root)
      restore(:workspaces_root, prev_root)
      restore(:workspace_source, prev_source)
      restore(:forward_auth, prev_forward_auth)
      restore(:preview_proxy_hmr, prev_hmr)
    end)

    # Upstream "dev server": a real WebSocket echo on the first free allowed port.
    upstream_port = start_upstream_echo!(@candidate_ports)

    # Real HTTP listener for the DevIDE endpoint on a free port.
    devide_port = free_port()

    start_supervised!(
      {Bandit, plug: DevIdeWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: devide_port}
    )

    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    {:ok, devide_port: devide_port, upstream_port: upstream_port, workspace_id: workspace_id}
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp start_upstream_echo!(ports) do
    Enum.find_value(ports, fn port ->
      case start_supervised(
             {Bandit, plug: EchoPlug, scheme: :http, ip: {127, 0, 0, 1}, port: port},
             id: {:echo, port}
           ) do
        {:ok, _pid} -> port
        {:error, _reason} -> nil
      end
    end) || flunk("no allowed dev port free to bind the upstream echo server")
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  test "a frame round-trips browser -> DevIDE -> upstream -> browser through the tunnel",
       %{devide_port: devide_port, upstream_port: upstream_port, workspace_id: workspace_id} do
    path = "/preview-proxy/#{workspace_id}/#{upstream_port}/socket"

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", devide_port, protocols: [:http1])

    {:ok, conn, ref} =
      Mint.WebSocket.upgrade(:ws, conn, path, [
        {"x-auth-request-email", "dev@local"},
        {"sec-websocket-protocol", "vite-hmr"}
      ])

    {:ok, conn, status, resp_headers} = await_upgrade(conn, ref)
    assert status == 101
    {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, resp_headers)

    {:ok, ws, data} = Mint.WebSocket.encode(ws, {:text, "hot-reload-ping"})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    assert {:text, "hot-reload-ping"} in recv_frames(conn, ws, ref)
  end

  defp await_upgrade(conn, ref, acc \\ %{status: nil, headers: [], done: false}) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)
        acc = Enum.reduce(responses, acc, &collect/2)

        if acc.done,
          do: {:ok, conn, acc.status, acc.headers},
          else: await_upgrade(conn, ref, acc)
    after
      5_000 -> flunk("websocket upgrade never completed")
    end
  end

  defp collect({:status, _ref, status}, acc), do: %{acc | status: status}
  defp collect({:headers, _ref, headers}, acc), do: %{acc | headers: headers}
  defp collect({:done, _ref}, acc), do: %{acc | done: true}
  defp collect(_other, acc), do: acc

  defp recv_frames(conn, ws, ref) do
    receive do
      message ->
        {:ok, _conn, responses} = Mint.WebSocket.stream(conn, message)
        data = for {:data, ^ref, bin} <- responses, into: <<>>, do: bin

        case data do
          <<>> ->
            recv_frames(conn, ws, ref)

          _ ->
            {:ok, _ws, frames} = Mint.WebSocket.decode(ws, data)
            frames
        end
    after
      5_000 -> flunk("no frame tunneled back from upstream")
    end
  end
end
