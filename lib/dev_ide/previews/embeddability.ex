defmodule DevIDE.Previews.Embeddability do
  @moduledoc """
  Decides whether an http(s) URL can be shown inside the preview iframe, or
  whether it hard-blocks framing and should open in a browser tab instead.

  A site blocks embedding with either response header:

    * `X-Frame-Options: DENY` / `SAMEORIGIN`
    * a CSP `frame-ancestors` directive that excludes us (anything without a
      `*` wildcard — `'none'`, `'self'`, or an explicit host allowlist)

  `frame_blocked?/1` is the pure header check (same semantics the Playwright
  adapter uses to fall back to a screenshot). `frame_blocked_url?/1` fetches the
  URL and applies it, but is deliberately **lenient**: it returns `true` only on
  a positive header block. Any network error, timeout, or ambiguous response
  returns `false` (\"don't divert\") so the caller proceeds with the normal
  preview-open path — which does its own reachability preflight — rather than
  punishing a slow-but-embeddable site. Workspace-local URLs served through the
  preview proxy have these headers stripped, so they are never blocked here.
  """

  @default_timeout_ms 1_500

  @doc """
  Fetch `url` and report whether the site hard-blocks iframe embedding.

  Returns `false` on any error/timeout/ambiguous response — only affirmative
  frame-blocking headers return `true`.
  """
  @spec frame_blocked_url?(String.t(), keyword()) :: boolean()
  def frame_blocked_url?(url, opts \\ [])

  def frame_blocked_url?(url, opts) when is_binary(url) do
    timeout =
      Keyword.get(opts, :timeout_ms) ||
        Application.get_env(:dev_ide, :preview_embed_check_timeout_ms, @default_timeout_ms)

    case Req.get(url,
           max_redirects: 3,
           retry: false,
           connect_options: [timeout: timeout],
           receive_timeout: timeout
         ) do
      {:ok, %{headers: headers}} -> frame_blocked?(headers)
      _ -> false
    end
  rescue
    # Req can raise on malformed URLs / adapter errors; treat as "unknown".
    _ -> false
  end

  def frame_blocked_url?(_url, _opts), do: false

  @doc """
  Pure check: do these response headers hard-block iframe embedding?

  Accepts the header-map shape Req and the Playwright adapter both produce
  (`%{"x-frame-options" => ["deny"]}` — values a list or a bare string).
  """
  @spec frame_blocked?(map()) :: boolean()
  def frame_blocked?(headers) when is_map(headers) do
    xframe_blocks?(header_value(headers, "x-frame-options")) or
      frame_ancestors_blocks?(header_value(headers, "content-security-policy"))
  end

  def frame_blocked?(_headers), do: false

  defp header_value(headers, key) do
    case Map.get(headers, key) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp xframe_blocks?(value) when is_binary(value) do
    value = String.downcase(value)
    String.contains?(value, "deny") or String.contains?(value, "sameorigin")
  end

  defp xframe_blocks?(_), do: false

  defp frame_ancestors_blocks?(csp) when is_binary(csp) do
    case Regex.run(~r/frame-ancestors([^;]*)/i, csp) do
      [_, sources] ->
        sources = sources |> String.trim() |> String.downcase()
        sources == "" or not String.contains?(sources, "*")

      _ ->
        false
    end
  end

  defp frame_ancestors_blocks?(_), do: false
end
