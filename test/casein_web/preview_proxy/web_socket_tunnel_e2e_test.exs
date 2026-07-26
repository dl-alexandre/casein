defmodule CaseinWeb.PreviewProxy.WebSocketTunnelE2ETest do
  @moduledoc """
  End-to-end proof that a WebSocket survives the *whole* stack: a real HTTP
  listener for `CaseinWeb.Endpoint`, the `:preview_proxy` pipeline + auth gate,
  the controller's `WebSockAdapter.upgrade` dispatch, the `WebSocketBridge`, and
  a real upstream dev-server socket. A `Mint.WebSocket` client drives it over a
  real TCP connection and asserts a frame round-trips browser→Casein→upstream→back.

  This closes the one seam the unit tests can't cross (route → upgrade → bridge
  over a real socket); the headed "edit file → HMR update in the browser" loop
  still has to be eyeballed against a real Vite app.
  """
  use Casein.DataCase, async: false

  alias Casein.PreviewPanes
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  # Loopback dev ports that are workspace-registered after binding; we use the
  # first free one since this box is busy and fixed ports collide.
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
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_source = Application.get_env(:casein, :workspace_source)
    prev_forward_auth = Application.get_env(:casein, :forward_auth)
    prev_hmr = Application.get_env(:casein, :preview_proxy_hmr)
    prev_tmux = Application.get_env(:casein, :tmux_adapter)

    root = Path.join(System.tmp_dir!(), "ws-e2e-#{System.unique_integer([:positive])}")
    path = Path.join([root, "dev", "ws"])
    File.mkdir_p!(path)
    Application.put_env(:casein, :workspaces_root, root)
    Application.put_env(:casein, :workspace_source, Casein.WorkspaceSource.Local)
    Application.put_env(:casein, :forward_auth, true)
    Application.put_env(:casein, :preview_proxy_hmr, enabled: true)
    Application.put_env(:casein, :tmux_adapter, FakeAdapter)
    PreviewPanes.clear()
    FakeState.delete(:fake_tmux_windows)
    FakeState.delete(:fake_tmux_panes)

    on_exit(fn ->
      PreviewPanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      File.rm_rf!(root)
      restore(:workspaces_root, prev_root)
      restore(:workspace_source, prev_source)
      restore(:forward_auth, prev_forward_auth)
      restore(:preview_proxy_hmr, prev_hmr)
      restore(:tmux_adapter, prev_tmux)
    end)

    # Upstream "dev server": a real WebSocket echo on the first free allowed port.
    upstream_port = start_upstream_echo!(@candidate_ports)

    session = "casein_ws_e2e"
    pane_id = "%9"
    seed_session!(session, pane_id)

    assert {:ok, _registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => ":#{upstream_port}",
               "cwd" => path,
               "tmux_session" => session
             })

    # Real HTTP listener for the Casein endpoint on a free port.
    casein_port = free_port()

    start_supervised!(
      {Bandit, plug: CaseinWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: casein_port}
    )

    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    {:ok, casein_port: casein_port, upstream_port: upstream_port, workspace_id: workspace_id}
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  defp seed_session!(session, pane_id) do
    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: pane_id,
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "casein-preview",
          current_path: "/tmp"
        }
      ]
    })
  end

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

  test "a frame round-trips browser -> Casein -> upstream -> browser through the tunnel",
       %{casein_port: casein_port, upstream_port: upstream_port, workspace_id: workspace_id} do
    path = "/preview-proxy/#{workspace_id}/#{upstream_port}/socket"

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", casein_port, protocols: [:http1])

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
