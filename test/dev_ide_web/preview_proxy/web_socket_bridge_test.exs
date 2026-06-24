defmodule DevIdeWeb.PreviewProxy.WebSocketBridgeTest do
  @moduledoc """
  Drives the `WebSock` callbacks of the bridge directly against a real upstream
  WebSocket echo server, so the `Mint.WebSocket` integration (handshake, encode,
  stream, decode) is exercised end to end without standing up the HTTP endpoint.

  The test process owns the Mint socket (callbacks run inline here), so upstream
  socket messages land in this mailbox and we feed them back via `handle_info/2`.
  """
  use ExUnit.Case, async: false

  alias DevIdeWeb.PreviewProxy.WebSocketBridge

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
end
