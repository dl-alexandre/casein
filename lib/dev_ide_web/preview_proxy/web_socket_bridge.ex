defmodule DevIdeWeb.PreviewProxy.WebSocketBridge do
  @moduledoc """
  A `WebSock` handler that tunnels a preview-pane WebSocket to a workspace's
  own loopback dev server, so HMR / LiveReload sockets (Vite, webpack, Phoenix
  LiveReload) survive being proxied through DevIDE's origin.

  The browser ↔ DevIDE hop is terminated by Bandit/`WebSockAdapter`; this handler
  is the DevIDE ↔ `127.0.0.1:PORT` hop, driven by `Mint.WebSocket`. Frames are
  forwarded verbatim in both directions; ping/pong/close are mirrored.

  ## Security

  This handler is only reached after `DevIdeWeb.PreviewProxyController` has run
  the same authorization gate as the HTTP proxy (owner check + `127.0.0.1` host
  pin + `Url.port_allowed?/2`). The upstream host is fixed to loopback by the
  caller; nothing in a browser frame can redirect the tunnel to another host.
  """

  @behaviour WebSock

  require Logger

  alias DevIdeWeb.PreviewProxy.WebSocketBridge.State

  @registry DevIdeWeb.PreviewProxy.WebSocketRegistry

  @doc "Number of live tunnels for a workspace (soft cap input for the controller)."
  @spec count(String.t()) :: non_neg_integer()
  def count(workspace_id), do: Registry.count_match(@registry, workspace_id, :_)

  defmodule State do
    @moduledoc false
    @enforce_keys [:workspace_id, :port]
    defstruct [:conn, :ref, :websocket, :workspace_id, :port, status: :open]
  end

  @typedoc """
  Init args assembled by the controller after authorization passes.

  `path` is the upstream request path (already including any query string), and
  `req_headers` are the browser's upgrade headers worth forwarding (e.g.
  `sec-websocket-protocol`).
  """
  @type init_arg :: %{
          required(:workspace_id) => String.t(),
          required(:port) => pos_integer(),
          required(:path) => String.t(),
          required(:req_headers) => [{String.t(), String.t()}]
        }

  @impl WebSock
  def init(%{workspace_id: workspace_id, port: port, path: path, req_headers: headers}) do
    Registry.register(@registry, workspace_id, port)
    state = %State{workspace_id: workspace_id, port: port}

    case connect_upstream(port, path, headers) do
      {:ok, conn, ref, websocket} ->
        {:ok, %{state | conn: conn, ref: ref, websocket: websocket}}

      {:error, reason} ->
        Logger.debug(
          "preview proxy ws upstream connect failed port=#{port} " <>
            "workspace_id=#{workspace_id} reason=#{inspect(reason)}"
        )

        # The browser hop is already upgraded; we can't refuse it, so signal the
        # failure as a normal close and stop.
        {:push, [{:close, 1011, "preview upstream unavailable"}], %{state | status: :closed}}
    end
  end

  # Browser → upstream. WebSock surfaces data frames as {payload, opcode: op}.
  @impl WebSock
  def handle_in({_payload, _opts}, %State{status: :closed} = state), do: {:ok, state}

  def handle_in({payload, [opcode: opcode]}, state) when opcode in [:text, :binary] do
    case send_upstream(state, {opcode, payload}) do
      {:ok, state} -> {:ok, state}
      {:error, state} -> {:stop, :normal, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  # Upstream socket activity (Mint runs in active mode, delivering to us).
  @impl WebSock
  def handle_info(message, %State{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, conn, reason, _responses} ->
        Logger.debug("preview proxy ws upstream stream error: #{inspect(reason)}")

        {:push, [{:close, 1011, "preview upstream error"}],
         %{state | conn: conn, status: :closed}}

      :unknown ->
        {:ok, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, %State{conn: conn}) when conn != nil do
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── upstream lifecycle ────────────────────────────────────────────────────

  defp connect_upstream(port, path, headers) do
    upgrade_headers = Enum.filter(headers, fn {k, _v} -> forward_upgrade_header?(k) end)

    with {:ok, conn} <-
           Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, upgrade_headers),
         {:ok, conn, status, resp_headers} <- await_upgrade(conn, ref),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, resp_headers) do
      {:ok, conn, ref, websocket}
    else
      {:error, _conn, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # Block until the 101 handshake completes. Bounded by the configured timeout so
  # a non-WS or hung upstream can't pin the connection process.
  defp await_upgrade(conn, ref, acc \\ %{status: nil, headers: []}) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            acc = collect_handshake(responses, ref, acc)

            if acc[:done],
              do: {:ok, conn, acc.status, acc.headers},
              else: await_upgrade(conn, ref, acc)

          {:error, _conn, reason, _responses} ->
            {:error, reason}

          :unknown ->
            await_upgrade(conn, ref, acc)
        end
    after
      handshake_timeout() -> {:error, :handshake_timeout}
    end
  end

  defp collect_handshake(responses, ref, acc) do
    Enum.reduce(responses, acc, fn
      {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
      {:headers, ^ref, headers}, acc -> Map.put(acc, :headers, headers)
      {:done, ^ref}, acc -> Map.put(acc, :done, true)
      _other, acc -> acc
    end)
  end

  defp send_upstream(%State{conn: conn, ref: ref, websocket: websocket} = state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        Logger.debug("preview proxy ws encode error: #{inspect(reason)}")
        {:error, %{state | websocket: websocket, status: :closed}}

      {:error, conn, reason} ->
        Logger.debug("preview proxy ws send error: #{inspect(reason)}")
        {:error, %{state | conn: conn, status: :closed}}
    end
  end

  # ── upstream → browser ──────────────────────────────────────────────────────

  defp handle_responses(responses, %State{ref: ref} = state) do
    data = for {:data, ^ref, bin} <- responses, into: <<>>, do: bin

    if data != <<>> do
      decode_and_push(data, state)
    else
      {:ok, state}
    end
  end

  defp decode_and_push(data, %State{websocket: websocket} = state) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        push_frames(frames, %{state | websocket: websocket})

      {:error, websocket, reason} ->
        Logger.debug("preview proxy ws decode error: #{inspect(reason)}")

        {:push, [{:close, 1011, "preview decode error"}],
         %{state | websocket: websocket, status: :closed}}
    end
  end

  # Translate upstream frames into browser pushes. A {:ping, _} is answered to
  # the upstream (not the browser); {:close, _, _} ends the tunnel.
  defp push_frames(frames, state) do
    frames
    |> Enum.reduce_while({[], state}, &fold_frame/2)
    |> emit()
  end

  defp fold_frame({opcode, payload}, {pushes, state}) when opcode in [:text, :binary],
    do: {:cont, {[{opcode, payload} | pushes], state}}

  defp fold_frame({:ping, payload}, {pushes, state}) do
    case send_upstream(state, {:pong, payload}) do
      {:ok, state} -> {:cont, {pushes, state}}
      {:error, state} -> {:halt, {[{:close, 1011, ""} | pushes], state}}
    end
  end

  defp fold_frame({:pong, _payload}, acc), do: {:cont, acc}

  defp fold_frame({:close, code, reason}, {pushes, state}),
    do:
      {:halt,
       {[{:close, close_code(code), to_string(reason)} | pushes], %{state | status: :closed}}}

  defp emit({pushes, %State{status: :closed} = state}),
    do: {:push, Enum.reverse(pushes), state}

  defp emit({[], state}), do: {:ok, state}
  defp emit({pushes, state}), do: {:push, Enum.reverse(pushes), state}

  # WebSock expects a valid close code; upstream may omit one.
  defp close_code(code) when is_integer(code) and code >= 1000, do: code
  defp close_code(_), do: 1000

  defp forward_upgrade_header?(name) do
    String.downcase(name) in ~w(sec-websocket-protocol)
  end

  defp handshake_timeout do
    :dev_ide
    |> Application.get_env(:preview_proxy_hmr, [])
    |> Keyword.get(:handshake_timeout_ms, 5_000)
  end
end
