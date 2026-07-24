defmodule CaseinWeb.PreviewProxy.WebSocketBridgeTest do
  @moduledoc """
  Drives the `WebSock` callbacks of the bridge directly against a real upstream
  WebSocket echo server, so the `Mint.WebSocket` integration (handshake, encode,
  stream, decode) is exercised end to end without standing up the HTTP endpoint.

  The test process owns the Mint socket (callbacks run inline here), so upstream
  socket messages land in this mailbox and we feed them back via `handle_info/2`.
  """
  use Casein.TestCase, async: false

  alias CaseinWeb.PreviewProxy.WebSocketBridge
  alias CaseinWeb.PreviewProxy.WebSocketBridge.State

  @registry CaseinWeb.PreviewProxy.WebSocketRegistry

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

    def call(conn, _opts) do
      conn |> WebSockAdapter.upgrade(EchoWS, [], []) |> halt()
    end
  end

  # Upstream that replies to any frame with a fixed set of frames — lets us drive
  # ping/close handling deterministically (the reply arrives as a fresh socket
  # message after the handshake, not buffered during it).
  defmodule ReplyWS do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(frames), do: {:ok, frames}

    @impl true
    def handle_in(_in, frames) do
      # A close must be signaled via {:stop, ...}; other frames are pushed.
      case List.keyfind(frames, :close, 0) do
        {:close, code, message} -> {:stop, :normal, {code, message}, frames}
        _ -> {:push, frames, frames}
      end
    end

    @impl true
    def handle_info(_msg, frames), do: {:ok, frames}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule ReplyPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, frames), do: conn |> WebSockAdapter.upgrade(ReplyWS, frames, []) |> halt()
  end

  defp start_reply_server!(frames) do
    port = free_port()

    start_supervised!(
      {Bandit, plug: {ReplyPlug, frames}, scheme: :http, ip: {127, 0, 0, 1}, port: port},
      id: {:reply, port}
    )

    port
  end

  # Receive one upstream socket message and feed it through handle_info/2.
  defp handle_next(state, timeout \\ 2_000) do
    receive do
      message -> WebSocketBridge.handle_info(message, state)
    after
      timeout -> flunk("no upstream message arrived")
    end
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp start_echo_server! do
    port = free_port()
    start_supervised!({Bandit, plug: EchoPlug, scheme: :http, ip: {127, 0, 0, 1}, port: port})
    port
  end

  defp init_bridge!(port) do
    assert {:ok, state} =
             WebSocketBridge.init(%{
               workspace_id: "ws-#{System.unique_integer([:positive])}",
               port: port,
               path: "/",
               req_headers: []
             })

    state
  end

  # Pump upstream socket messages through handle_info until a frame is pushed.
  defp drain(state) do
    receive do
      message ->
        case WebSocketBridge.handle_info(message, state) do
          {:ok, state} -> drain(state)
          {:push, frames, state} -> {frames, state}
        end
    after
      2_000 -> flunk("no frames pushed from upstream")
    end
  end

  test "tunnels a text frame to the upstream and echoes it back" do
    port = start_echo_server!()
    state = init_bridge!(port)

    assert {:ok, state} = WebSocketBridge.handle_in({"hot-reload", [opcode: :text]}, state)
    assert {[{:text, "hot-reload"}], _state} = drain(state)
  end

  test "tunnels a binary frame both directions" do
    port = start_echo_server!()
    state = init_bridge!(port)

    payload = <<1, 2, 3, 250, 0, 99>>
    assert {:ok, state} = WebSocketBridge.handle_in({payload, [opcode: :binary]}, state)
    assert {[{:binary, ^payload}], _state} = drain(state)
  end

  test "init closes the browser hop when the upstream is not a websocket server" do
    # A plain TCP server that answers the upgrade with 200, not 101.
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, _req} = :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
    end)

    assert {:push, [{:close, 1011, _reason}], _state} =
             WebSocketBridge.init(%{
               workspace_id: "ws-nope",
               port: port,
               path: "/",
               req_headers: []
             })

    :gen_tcp.close(listen)
  end

  test "init closes the browser hop when the upstream port is not listening" do
    # free_port/0 returns a port with nothing bound, so connect is refused.
    port = free_port()

    assert {:push, [{:close, 1011, _reason}], _state} =
             WebSocketBridge.init(%{workspace_id: "w", port: port, path: "/", req_headers: []})
  end

  test "init closes the browser hop when the upstream never completes the handshake" do
    prev = Application.get_env(:dev_ide, :preview_proxy_hmr)
    Application.put_env(:dev_ide, :preview_proxy_hmr, handshake_timeout_ms: 150)
    on_exit(fn -> restore(:preview_proxy_hmr, prev) end)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    # Accept but never answer, so the upgrade stalls past the timeout.
    spawn_link(fn -> {:ok, _socket} = :gen_tcp.accept(listen) end)

    assert {:push, [{:close, 1011, _reason}], _state} =
             WebSocketBridge.init(%{workspace_id: "w", port: port, path: "/", req_headers: []})

    :gen_tcp.close(listen)
  end

  test "answers an upstream ping without forwarding it to the browser" do
    port = start_reply_server!([{:ping, "are-you-there"}])
    state = init_bridge!(port)

    {:ok, state} = WebSocketBridge.handle_in({"trigger", [opcode: :text]}, state)
    assert {:ok, _state} = handle_next(state)
  end

  test "ignores an upstream pong" do
    port = start_reply_server!([{:pong, "pong-data"}])
    state = init_bridge!(port)

    {:ok, state} = WebSocketBridge.handle_in({"trigger", [opcode: :text]}, state)
    assert {:ok, _state} = handle_next(state)
  end

  test "forwards an upstream close to the browser and marks the tunnel closed" do
    port = start_reply_server!([{:close, 1001, "going away"}])
    state = init_bridge!(port)

    {:ok, state} = WebSocketBridge.handle_in({"trigger", [opcode: :text]}, state)
    assert {:push, [{:close, 1001, "going away"}], %State{status: :closed}} = handle_next(state)
  end

  test "terminate/2 closes a live upstream connection" do
    port = start_echo_server!()
    state = init_bridge!(port)

    assert :ok = WebSocketBridge.terminate(:shutdown, state)
  end

  test "terminate/2 is a no-op without an upstream connection" do
    assert :ok =
             WebSocketBridge.terminate(:shutdown, %State{workspace_id: "w", port: 1, conn: nil})
  end

  test "handle_in/2 drops frames once the tunnel is closed" do
    state = %State{workspace_id: "w", port: 1, status: :closed}
    assert {:ok, ^state} = WebSocketBridge.handle_in({"x", [opcode: :text]}, state)
  end

  test "handle_in/2 ignores non-data frames" do
    state = %State{workspace_id: "w", port: 1}
    assert {:ok, ^state} = WebSocketBridge.handle_in({"x", [opcode: :ping]}, state)
  end

  test "handle_info/2 ignores messages when there is no upstream connection" do
    state = %State{workspace_id: "w", port: 1, conn: nil}
    assert {:ok, ^state} = WebSocketBridge.handle_info(:tcp_closed, state)
  end

  test "handle_info/2 ignores unrelated socket messages" do
    port = start_echo_server!()
    state = init_bridge!(port)

    assert {:ok, _state} = WebSocketBridge.handle_info({:unexpected, :message}, state)
  end

  test "count/0 reflects live tunnel registrations for a workspace" do
    wsid = "count-#{System.unique_integer([:positive])}"
    assert WebSocketBridge.count(wsid) == 0

    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        Registry.register(@registry, wsid, 1)
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    assert WebSocketBridge.count(wsid) == 1

    Process.exit(pid, :kill)
  end

  test "stops the tunnel when sending to a closed upstream fails" do
    port = start_echo_server!()
    state = init_bridge!(port)
    {:ok, closed_conn} = Mint.HTTP.close(state.conn)
    closed = %{state | conn: closed_conn}

    assert {:stop, :normal, _state} = WebSocketBridge.handle_in({"x", [opcode: :text]}, closed)
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)
end
