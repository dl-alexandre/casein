defmodule DevIdeWeb.PreviewProxyController do
  @moduledoc """
  Reverse proxy that makes a workspace's own loopback dev server embeddable in
  a preview iframe even when it sends frame-blocking headers.

  Instead of degrading a frame-blocked app to a static screenshot, DevIDE
  fetches it server-side and re-serves it from its own origin with
  `x-frame-options` / CSP `frame-ancestors` stripped, so it stays live and
  interactive inside the preview pane.

  ## Security

  The upstream host is hard-coded to `127.0.0.1` and the port is validated
  against `DevIDE.Previews.Url.port_allowed?/2` (common dev ports, workspace
  metadata ports, and already-detected ports). Combined with the
  owner/admin authorization gate, the only thing this endpoint can reach is a
  loopback port the requesting user is already allowed to preview — it is not a
  general-purpose forward proxy.

  ## Scope

  Targets frame-blocked static/SSR apps on loopback, including Phoenix LiveView
  pages that can use long-poll fallback. A `<base href>` is injected so relative
  sub-resources route back through the proxy; root-relative HTML/CSS assets and
  standard Phoenix socket endpoint literals (`/live`, `/socket`,
  `/phoenix/live_reload/socket`) are rewritten under the proxy prefix.

  ## HMR / WebSocket tunneling

  When `:preview_proxy_hmr` is enabled, the proxy additionally tunnels WebSocket
  upgrades to the workspace dev server (`DevIdeWeb.PreviewProxy.WebSocketBridge`,
  via `Mint.WebSocket`) and injects an import map + WebSocket-reroute shim plus
  loopback-origin rewriting (see `Rewrite.inject_hmr_assets/2` and
  `Rewrite.rewrite_loopback_origins/2`) so Vite / webpack HMR and Phoenix
  LiveReload survive being proxied. The upgrade reuses this controller's
  owner/SSRF gate, is capped per workspace, and is **disabled by default** —
  flag-off behavior is exactly the static/SSR proxy above, unchanged.
  """
  use DevIdeWeb, :controller

  require Logger

  alias DevIDE.PreviewPanes
  alias DevIDE.Previews.Url
  alias DevIDE.Previews.WorkspaceContext
  alias DevIDE.Workspaces
  alias DevIdeWeb.PreviewProxy.Rewrite
  alias DevIdeWeb.PreviewProxy.WebSocketBridge

  # Don't JSON/term-decode the body (we forward bytes), don't follow redirects
  # (the browser should see them, rewritten), bounded timeouts. Decompression
  # stays on so we can inject <base> into HTML; we strip content-encoding below.
  @req_opts [
    decode_body: false,
    redirect: false,
    retry: false,
    connect_options: [timeout: 5_000],
    receive_timeout: 15_000
  ]

  @spec proxy(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def proxy(conn, %{"workspace_id" => workspace_id, "port" => port_str} = params) do
    path_parts = Map.get(params, "path", [])

    with {:ok, port} <- parse_port(port_str),
         {:ok, workspace} <- load_authorized(conn, workspace_id),
         workspace <- WorkspaceContext.prepare(workspace),
         true <- port_allowed?(port, workspace_id, workspace) do
      if websocket_upgrade?(conn) do
        upgrade_tunnel(conn, port, path_parts, workspace_id)
      else
        upstream = build_upstream(port, path_parts, conn.query_string)
        fetch_and_stream(conn, upstream, workspace_id, port)
      end
    else
      :forbidden -> conn |> put_status(403) |> text("Forbidden")
      {:error, :bad_port} -> conn |> put_status(400) |> text("Invalid port")
      false -> conn |> put_status(403) |> text("Port not allowed for this workspace")
      _ -> conn |> put_status(404) |> text("Not found")
    end
  end

  defp load_authorized(conn, workspace_id) do
    viewer = conn.assigns[:current_user]
    auth = viewer && Map.get(viewer, :email)

    case Workspaces.get(workspace_id, auth) do
      {:ok, workspace} ->
        if Workspaces.viewer_terminal_owner?(workspace, viewer || %{}),
          do: {:ok, workspace},
          else: :forbidden

      # Don't distinguish "not found" from "not yours" — avoid leaking existence.
      _ ->
        :forbidden
    end
  end

  defp parse_port(port_str) do
    case Integer.parse(port_str) do
      {port, ""} when port > 0 and port < 65_536 -> {:ok, port}
      _ -> {:error, :bad_port}
    end
  end

  defp port_allowed?(port, workspace_id, workspace) do
    Url.port_allowed?(port, workspace) or registered_preview_port?(workspace_id, port)
  end

  defp registered_preview_port?(workspace_id, port) do
    workspace_id
    |> PreviewPanes.list_for_workspace()
    |> Enum.any?(fn registration ->
      preview_port(registration.url) == port or preview_port(registration.display_url) == port
    end)
  end

  defp preview_port(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{port: port} when is_integer(port) -> port
      %URI{path: "/preview-proxy/" <> _ = path} -> preview_proxy_port(path)
      _ -> nil
    end
  end

  defp preview_port(_), do: nil

  defp preview_proxy_port(path) do
    case String.split(path, "/", parts: 5) do
      ["", "preview-proxy", _workspace_id, port, _rest] -> parse_proxy_port(port)
      ["", "preview-proxy", _workspace_id, port] -> parse_proxy_port(port)
      _ -> nil
    end
  end

  defp parse_proxy_port(port) do
    case Integer.parse(port) do
      {port, ""} -> port
      _ -> nil
    end
  end

  # Host is fixed; only the path/query come from the request, so the request
  # cannot redirect the fetch to another host.
  defp build_upstream(port, path_parts, query) do
    path = "/" <> Enum.map_join(path_parts, "/", &URI.encode/1)
    base = "http://127.0.0.1:#{port}#{path}"
    if query in [nil, ""], do: base, else: base <> "?" <> query
  end

  # A WebSocket upgrade arrives as a GET with `Upgrade: websocket` and a
  # `Connection` header listing `upgrade`. Authorization has already passed by
  # the time we get here, so we only decide whether to tunnel.
  defp websocket_upgrade?(conn) do
    header_contains?(conn, "upgrade", "websocket") and
      header_contains?(conn, "connection", "upgrade")
  end

  defp header_contains?(conn, name, needle) do
    conn
    |> Plug.Conn.get_req_header(name)
    |> Enum.any?(fn value -> String.contains?(String.downcase(value), needle) end)
  end

  defp upgrade_tunnel(conn, port, path_parts, workspace_id) do
    cfg = hmr_config()

    cond do
      not Keyword.get(cfg, :enabled, false) ->
        conn |> put_status(426) |> text("WebSocket preview proxying is disabled")

      WebSocketBridge.count(workspace_id) >= Keyword.get(cfg, :max_per_workspace, 8) ->
        conn |> put_status(429) |> text("Too many preview WebSocket connections")

      true ->
        init = %{
          workspace_id: workspace_id,
          port: port,
          path: build_upstream_path(path_parts, conn.query_string),
          req_headers: conn.req_headers
        }

        conn
        |> echo_ws_subprotocol()
        |> WebSockAdapter.upgrade(WebSocketBridge, init,
          timeout: Keyword.get(cfg, :idle_timeout_ms, 60_000)
        )
        |> halt()
    end
  end

  # Optimistically echo the first subprotocol the browser offered (e.g. Vite's
  # `vite-hmr`) so clients that key off `ws.protocol` are satisfied. The browser
  # establishes the socket regardless; the upstream negotiates independently in
  # the bridge.
  defp echo_ws_subprotocol(conn) do
    case conn |> Plug.Conn.get_req_header("sec-websocket-protocol") |> List.first() do
      value when is_binary(value) ->
        case value |> String.split(",") |> List.first() |> String.trim() do
          "" -> conn
          proto -> Plug.Conn.put_resp_header(conn, "sec-websocket-protocol", proto)
        end

      _ ->
        conn
    end
  end

  # Path (with query) for the upstream WS handshake; host/scheme are fixed by the
  # bridge, so only the request-target comes from the caller.
  defp build_upstream_path(path_parts, query) do
    path = "/" <> Enum.map_join(path_parts, "/", &URI.encode/1)
    if query in [nil, ""], do: path, else: path <> "?" <> query
  end

  defp hmr_config, do: Application.get_env(:dev_ide, :preview_proxy_hmr, [])

  # sobelow_skip ["XSS.SendResp"]
  # Re-serving the upstream body verbatim IS the feature: the user's own,
  # authorized loopback app rendered live. The body is never DevIDE-trusted
  # markup, and the response carries no DevIDE session/CSP authority (see the
  # :preview_proxy pipeline) — it runs as the proxied app's own document.
  defp fetch_and_stream(conn, url, workspace_id, port) do
    maybe_log_transport_request(conn, url, workspace_id, port)

    case Req.request(proxy_request_opts(conn, url)) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        content_type = Rewrite.first_header(headers, "content-type")

        conn
        |> put_forward_headers(headers)
        |> maybe_put_content_type(content_type)
        |> send_resp(status, rewrite_body(body, content_type, workspace_id, port))

      {:error, reason} ->
        Logger.debug("preview proxy upstream error for #{url}: #{inspect(reason)}")
        not_running(conn, port)
    end
  end

  defp maybe_log_transport_request(conn, url, workspace_id, port) do
    case URI.parse(url).path do
      path when is_binary(path) ->
        if phoenix_transport_path?(path) do
          Logger.debug(
            "preview proxy Phoenix transport request method=#{conn.method} " <>
              "path=#{path} port=#{port} workspace_id=#{workspace_id}"
          )
        end

      _ ->
        :ok
    end
  end

  defp phoenix_transport_path?(path) do
    Enum.any?(["/live", "/socket", "/phoenix/live_reload/socket"], fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end

  defp proxy_request_opts(conn, url) do
    @req_opts
    |> Keyword.merge(
      method: req_method(conn.method),
      url: url,
      headers: forward_request_headers(conn)
    )
    |> maybe_put_body(read_proxy_body(conn))
  end

  defp req_method("GET"), do: :get
  defp req_method("POST"), do: :post
  defp req_method("PUT"), do: :put
  defp req_method("PATCH"), do: :patch
  defp req_method("DELETE"), do: :delete
  defp req_method("HEAD"), do: :head
  defp req_method("OPTIONS"), do: :options
  defp req_method(_), do: :get

  defp read_proxy_body(%{method: method}) when method in ~w(GET HEAD OPTIONS), do: ""

  defp read_proxy_body(conn) do
    case conn.private[:devide_preview_proxy_raw_body] do
      body when is_binary(body) ->
        body

      _ ->
        case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
          {:ok, body, _conn} -> body
          {:more, body, _conn} -> body
          {:error, _reason} -> ""
        end
    end
  end

  defp maybe_put_body(opts, ""), do: opts
  defp maybe_put_body(opts, body), do: Keyword.put(opts, :body, body)

  defp forward_request_headers(conn) do
    conn.req_headers
    |> Enum.reject(fn {name, _value} -> drop_request_header?(name) end)
    |> Enum.map(fn
      {"host", _value} -> {"host", "127.0.0.1"}
      header -> header
    end)
  end

  defp drop_request_header?(name) do
    String.downcase(name) in ~w(
      connection content-length keep-alive proxy-authenticate proxy-authorization
      trailer transfer-encoding upgrade
    )
  end

  defp put_forward_headers(conn, headers) do
    Plug.Conn.prepend_resp_headers(conn, Rewrite.forward_headers(headers))
  end

  defp maybe_put_content_type(conn, nil), do: conn
  # put_resp_content_type/2 appends "; charset=..." and rejects values with
  # existing parameters; the upstream value is authoritative, so set it raw.
  defp maybe_put_content_type(conn, content_type),
    do: Plug.Conn.put_resp_header(conn, "content-type", content_type)

  defp rewrite_body(body, content_type, workspace_id, port) when is_binary(body) do
    proxy_prefix = "/preview-proxy/#{workspace_id}/#{port}/"

    cond do
      Rewrite.html?(content_type) ->
        body
        |> Rewrite.inject_base(proxy_prefix)
        |> maybe_inject_hmr_assets(proxy_prefix)
        |> maybe_rewrite_loopback_origins(workspace_id)

      Rewrite.css?(content_type) ->
        body
        |> Rewrite.rewrite_css_urls(proxy_prefix)
        |> maybe_rewrite_loopback_origins(workspace_id)

      Rewrite.javascript?(content_type) ->
        body
        |> Rewrite.rewrite_phoenix_socket_paths(proxy_prefix)
        |> maybe_rewrite_loopback_origins(workspace_id)

      Rewrite.javascript?(content_type) ->
        Rewrite.rewrite_phoenix_socket_paths(body, proxy_prefix)

      true ->
        body
    end
  end

  # HMR support (import map + WebSocket reroute shim) layers on top of the base
  # rewrites, only when the tunnel is enabled, so flag-off proxying of SSR apps
  # stays byte-identical.
  defp maybe_inject_hmr_assets(html, proxy_prefix) do
    if Keyword.get(hmr_config(), :enabled, false),
      do: Rewrite.inject_hmr_assets(html, proxy_prefix),
      else: html
  end

  defp maybe_rewrite_loopback_origins(body, workspace_id) do
    if Keyword.get(hmr_config(), :enabled, false),
      do: Rewrite.rewrite_loopback_origins(body, workspace_id),
      else: body
  end

  # sobelow_skip ["XSS.SendResp"]
  # `port` is a validated integer (0 < port < 65_536); no user string reaches
  # this static page.
  defp not_running(conn, port) do
    html = """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      body { margin:0; font-family: ui-sans-serif, system-ui, sans-serif; background:#0b0b0c; color:#d4d4d8;
             display:flex; align-items:center; justify-content:center; height:100vh; }
      .card { text-align:center; padding:2rem; }
      .port { color:#a1a1aa; font-variant-numeric: tabular-nums; }
    </style></head>
    <body><div class="card">
      <h2>Nothing is listening on port #{port}</h2>
      <p class="port">Start your dev server in the workspace, then reload this preview.</p>
    </div></body></html>
    """

    conn |> put_resp_header("content-type", "text/html; charset=utf-8") |> send_resp(502, html)
  end
end
