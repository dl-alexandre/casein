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
  value}]` list with frame-blocking and framing headers removed.
  """
  @spec forward_headers([{String.t(), term()}] | map()) :: [{String.t(), String.t()}]
  def forward_headers(headers) do
    headers
    |> Enum.reject(fn {k, _v} -> droppable_header?(k) end)
    |> Enum.map(fn {k, v} -> {String.downcase(k), header_value(v)} end)
  end

  @doc "True for an HTML content-type."
  @spec html?(String.t() | nil) :: boolean()
  def html?(content_type), do: is_binary(content_type) and String.contains?(content_type, "html")

  @doc "True for a CSS content-type."
  @spec css?(String.t() | nil) :: boolean()
  def css?(content_type), do: is_binary(content_type) and String.contains?(content_type, "css")

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
