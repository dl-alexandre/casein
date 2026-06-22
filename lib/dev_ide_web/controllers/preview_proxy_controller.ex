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

  ## Scope (v1)

  Targets frame-blocked static/SSR apps on loopback. A `<base href>` is injected
  so *relative* sub-resources route back through the proxy; root-relative
  (`/assets/...`) URLs and `ws://` (HMR/LiveReload) are **not** rewritten and
  keep talking to the origin directly — HMR dev servers should use the direct
  embed. See the plan's Risks section.
  """
  use DevIdeWeb, :controller

  require Logger

  alias DevIDE.PreviewPanes
  alias DevIDE.Previews.Url
  alias DevIDE.Previews.WorkspaceContext
  alias DevIDE.Workspaces
  alias DevIdeWeb.PreviewProxy.Rewrite

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
      upstream = build_upstream(port, path_parts, conn.query_string)
      fetch_and_stream(conn, upstream, workspace_id, port)
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

  # sobelow_skip ["XSS.SendResp"]
  # Re-serving the upstream body verbatim IS the feature: the user's own,
  # authorized loopback app rendered live. The body is never DevIDE-trusted
  # markup, and the response carries no DevIDE session/CSP authority (see the
  # :preview_proxy pipeline) — it runs as the proxied app's own document.
  defp fetch_and_stream(conn, url, workspace_id, port) do
    case Req.get(url, @req_opts) do
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

  defp put_forward_headers(conn, headers) do
    headers
    |> Rewrite.forward_headers()
    |> Enum.reduce(conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)
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
        Rewrite.inject_base(body, proxy_prefix)

      Rewrite.css?(content_type) ->
        Rewrite.rewrite_css_urls(body, proxy_prefix)

      true ->
        body
    end
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
