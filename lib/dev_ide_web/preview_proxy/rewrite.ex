defmodule DevIdeWeb.PreviewProxy.Rewrite do
  @moduledoc """
  Pure header/body transforms for `DevIdeWeb.PreviewProxyController`.

  Kept separate from the controller so the security-relevant rules — which
  upstream headers are dropped, and how `<base>` is injected — are unit-testable
  without a live HTTP round-trip.
  """

  # Response headers we never forward: frame blockers (the whole point of the
  # proxy) and framing/length headers that no longer match the re-served body.
  @drop_resp_headers ~w(
    x-frame-options content-security-policy content-security-policy-report-only
    content-length content-encoding transfer-encoding connection
    keep-alive proxy-authenticate trailer upgrade strict-transport-security
    cross-origin-embedder-policy cross-origin-opener-policy cross-origin-resource-policy
  )

  @doc "True when a response header must not be forwarded to the browser."
  @spec droppable_header?(String.t()) :: boolean()
  def droppable_header?(name) when is_binary(name),
    do: String.downcase(name) in @drop_resp_headers

  @doc """
  Filter and normalize upstream response headers for re-serving.

  Accepts Req's map or list header shapes and returns a `[{downcased_name,
  value}]` list with frame-blocking and framing headers removed. Repeated
  upstream headers, especially `set-cookie`, are preserved as repeated tuples.
  """
  @spec forward_headers([{String.t(), term()}] | map()) :: [{String.t(), String.t()}]
  def forward_headers(headers) do
    headers
    |> Enum.reject(fn {k, _v} -> droppable_header?(k) end)
    |> Enum.flat_map(fn {k, v} ->
      name = String.downcase(k)
      Enum.map(header_values(v), &{name, &1})
    end)
  end

  @doc "True for an HTML content-type."
  @spec html?(String.t() | nil) :: boolean()
  def html?(content_type), do: is_binary(content_type) and String.contains?(content_type, "html")

  @doc "True for a CSS content-type."
  @spec css?(String.t() | nil) :: boolean()
  def css?(content_type), do: is_binary(content_type) and String.contains?(content_type, "css")

  @doc "True for a JavaScript content-type."
  @spec javascript?(String.t() | nil) :: boolean()
  def javascript?(content_type) when is_binary(content_type) do
    content_type = String.downcase(content_type)
    String.contains?(content_type, "javascript") or String.contains?(content_type, "ecmascript")
  end

  def javascript?(_), do: false

  @doc """
  Insert `<base href>` as the first child of `<head>` so the proxied page's
  *relative* sub-resources resolve back through the proxy, and rewrite
  root-relative `href` / `src` / `action` attributes to the same proxy prefix.

  No-ops for base insertion when the document already has a `<base>` or has no
  `<head>`. Root-relative attribute rewrites still run, because `<base>` does
  not affect paths that begin with `/`.
  """
  @spec inject_base(String.t(), String.t()) :: String.t()
  def inject_base(html, base_href) when is_binary(html) do
    tag = ~s(<base href="#{base_href}">#{sandbox_storage_shim()})

    html =
      cond do
        Regex.match?(~r/<base\b/i, html) ->
          html

        Regex.match?(~r/<head\b[^>]*>/i, html) ->
          Regex.replace(~r/(<head\b[^>]*>)/i, html, "\\1#{tag}", global: false)

        true ->
          html
      end

    rewrite_root_relative_attrs(html, base_href)
  end

  @doc """
  Rewrite root-relative HTML attributes so proxied pages fetch their own assets
  and navigate within the proxied app instead of DevIDE's origin root.
  """
  @spec rewrite_root_relative_attrs(String.t(), String.t()) :: String.t()
  def rewrite_root_relative_attrs(html, proxy_prefix)
      when is_binary(html) and is_binary(proxy_prefix) do
    prefix = ensure_trailing_slash(proxy_prefix)

    attr_regex =
      ~r/\b(href|src|action)=(["'])\/(?!\/|preview-proxy\/|preview-artifacts\/)([^"']*)\2/i

    Regex.replace(
      ~r/<(?!base\b)([^>]+)>/i,
      html,
      fn tag, _inner ->
        Regex.replace(attr_regex, tag, fn _match, attr, quote, path ->
          attr <> "=" <> quote <> prefix <> path <> quote
        end)
      end
    )
  end

  @doc "Rewrite root-relative CSS url(...) references through the proxy prefix."
  @spec rewrite_css_urls(String.t(), String.t()) :: String.t()
  def rewrite_css_urls(css, proxy_prefix) when is_binary(css) and is_binary(proxy_prefix) do
    prefix = ensure_trailing_slash(proxy_prefix)

    Regex.replace(
      ~r/url\((["']?)\/(?!\/|preview-proxy\/|preview-artifacts\/)([^)"']*)\1\)/i,
      css,
      fn _match, quote, path ->
        "url(" <> quote <> prefix <> path <> quote <> ")"
      end
    )
  end

  @doc """
  Rewrite standard Phoenix socket endpoint string literals in JavaScript.

  Phoenix generators usually construct LiveView and LiveReload clients with
  absolute-root endpoints like `new LiveSocket("/live", ...)` or
  `new Socket("/socket", ...)`. Inside a preview proxy iframe those paths point
  at DevIDE itself, not the proxied loopback app. Rewriting just these endpoint
  literals keeps the initial websocket attempt and the long-poll fallback on the
  same proxied origin/path.
  """
  @spec rewrite_phoenix_socket_paths(String.t(), String.t()) :: String.t()
  def rewrite_phoenix_socket_paths(js, proxy_prefix)
      when is_binary(js) and is_binary(proxy_prefix) do
    prefix = ensure_trailing_slash(proxy_prefix)

    Regex.replace(
      ~r/(["'])\/(live|socket|phoenix\/live_reload\/socket)(\?[^"']*)?\1/,
      js,
      fn _match, quote, path, query ->
        quote <> prefix <> path <> (query || "") <> quote
      end
    )
  end

  @doc """
  Inject HMR support assets as the first children of `<head>`:

    * an **import map** remapping root-absolute ES module specifiers
      (`/@vite/client`, `/@id/...`, `/node_modules/...`) through the proxy
      prefix — `<base>` does not affect module specifier resolution, so module
      graphs need this to load through the proxy; and
    * a **WebSocket shim** that reroutes same-origin sockets (Vite / webpack HMR,
      Phoenix LiveReload) under the proxy prefix, so the tunnel
      (`DevIdeWeb.PreviewProxy.WebSocketBridge`) catches them instead of them
      hitting DevIDE's own origin root.

  No-ops without a `<head>`. The import map is skipped if the document already
  ships one (only one import map is allowed per document); the WebSocket shim is
  always injected. Intended to run after `inject_base/2`, gated by the
  `:preview_proxy_hmr` flag in the controller.
  """
  @spec inject_hmr_assets(String.t(), String.t()) :: String.t()
  def inject_hmr_assets(html, proxy_prefix) when is_binary(html) and is_binary(proxy_prefix) do
    prefix = ensure_trailing_slash(proxy_prefix)

    if Regex.match?(~r/<head\b[^>]*>/i, html) do
      assets = hmr_import_map(html, prefix) <> websocket_reroute_shim(prefix, proxy_wsid(prefix))
      Regex.replace(~r/(<head\b[^>]*>)/i, html, "\\1#{assets}", global: false)
    else
      html
    end
  end

  defp hmr_import_map(html, prefix) do
    if Regex.match?(~r/<script[^>]*type=("|')importmap\1/i, html) do
      ""
    else
      ~s(<script type="importmap">{"imports":{"/":"#{prefix}"}}</script>)
    end
  end

  # Reroute HMR/LiveReload sockets under the proxy prefix so the tunnel catches
  # them. Two cases are rerouted, both at runtime so they're version-agnostic:
  #   * same-origin sockets (client derived its URL from the iframe origin, which
  #     is DevIDE) not already under the prefix; and
  #   * absolute loopback sockets (`ws://localhost:PORT/...`) — same-origin checks
  #     miss these, but the browser can't reach a server-side loopback either.
  # Cross-origin (non-loopback) sockets and already-prefixed paths are left alone.
  defp websocket_reroute_shim(prefix, wsid) do
    """
    <script>
    (() => {
      const PREFIX = "#{prefix}";
      const WSID = "#{wsid}";
      const Native = window.WebSocket;
      if (!Native) return;
      const wsProto = () => location.protocol === "https:" ? "wss:" : "ws:";
      const proxied = (port, path, search) =>
        wsProto() + "//" + location.host + "/preview-proxy/" + WSID + "/" + port + path + search;
      const reroute = (url) => {
        try {
          const u = new URL(url, location.href);
          if (u.protocol !== "ws:" && u.protocol !== "wss:") return url;
          if (u.host === location.host) {
            if (u.pathname.startsWith(PREFIX)) return url;
            return wsProto() + "//" + location.host + PREFIX + u.pathname.replace(/^\\//, "") + u.search;
          }
          if (WSID && (u.hostname === "localhost" || u.hostname === "127.0.0.1")) {
            const port = u.port || (u.protocol === "wss:" ? "443" : "80");
            return proxied(port, u.pathname, u.search);
          }
        } catch (_) {}
        return url;
      };
      const Patched = new Proxy(Native, {
        construct(target, args) {
          if (args.length) args[0] = reroute(args[0]);
          return new target(...args);
        }
      });
      window.WebSocket = Patched;
    })();
    </script>
    """
  end

  defp proxy_wsid(prefix) do
    case String.split(prefix, "/", trim: true) do
      ["preview-proxy", wsid | _] -> wsid
      _ -> ""
    end
  end

  @doc """
  Rewrite absolute loopback origins (`http(s)://localhost:PORT`,
  `ws(s)://127.0.0.1:PORT`, …) to a root-relative proxy path for the same port.

  Sub-resources and sockets hard-coded to a workspace's own loopback origin are
  unreachable from the browser through a proxied iframe; this points them back at
  the proxy. Scheme is dropped so the result resolves same-origin (http→fetch,
  ws→`new WebSocket`). Only loopback hosts are touched, so external URLs are
  untouched.
  """
  @spec rewrite_loopback_origins(String.t(), String.t()) :: String.t()
  def rewrite_loopback_origins(body, workspace_id)
      when is_binary(body) and is_binary(workspace_id) do
    Regex.replace(
      ~r{(?:https?|wss?)://(?:localhost|127\.0\.0\.1):(\d+)},
      body,
      fn _match, port -> "/preview-proxy/#{workspace_id}/#{port}" end
    )
  end

  @doc "First value for `key` from Req's map or list header shapes, or nil."
  @spec first_header([{String.t(), term()}] | map(), String.t()) :: String.t() | nil
  def first_header(headers, key) when is_map(headers) do
    case Map.get(headers, key) || Map.get(headers, String.downcase(key)) do
      [v | _] -> v
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  def first_header(headers, key) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == key, do: header_value(v)
    end)
  end

  @doc false
  def header_value([v | _]), do: v
  def header_value(v) when is_binary(v), do: v
  def header_value(v), do: to_string(v)

  defp header_values(values) when is_list(values), do: Enum.map(values, &header_value/1)
  defp header_values(value), do: [header_value(value)]

  defp ensure_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end

  defp sandbox_storage_shim do
    """
    <script>
    (() => {
      const install = (name) => {
        try {
          window[name];
          return;
        } catch (_) {}

        const data = new Map();
        const store = {
          get length() { return data.size; },
          key: (index) => Array.from(data.keys())[index] || null,
          getItem: (key) => data.has(String(key)) ? data.get(String(key)) : null,
          setItem: (key, value) => data.set(String(key), String(value)),
          removeItem: (key) => data.delete(String(key)),
          clear: () => data.clear()
        };

        try {
          Object.defineProperty(window, name, {value: store, configurable: true});
        } catch (_) {}
      };

      install("localStorage");
      install("sessionStorage");

      try {
        document.cookie;
      } catch (_) {
        let cookie = "";
        try {
          Object.defineProperty(document, "cookie", {
            configurable: true,
            get: () => cookie,
            set: (value) => {
              cookie = cookie ? cookie + "; " + String(value).split(";")[0] : String(value).split(";")[0];
            }
          });
        } catch (_) {}
      }
    })();
    </script>
    """
  end
end
