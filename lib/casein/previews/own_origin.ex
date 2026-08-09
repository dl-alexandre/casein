defmodule Casein.Previews.OwnOrigin do
  @moduledoc """
  Host-per-preview routing: serve a workspace's loopback dev server from its own
  hostname instead of a path prefix under the cockpit origin.

  ## Why this exists

  The `/preview-proxy/<workspace>/<port>/` path proxy re-serves a workspace app
  from Casein's own origin. That works for static/SSR pages, but it breaks
  LiveView outright: on every channel join the client sends `window.location.href`
  as the `url` connect param, and `Phoenix.LiveView.Channel.authorize_session/3`
  matches it against *the proxied app's own router*. `/preview-proxy/<ws>/<port>/login`
  matches nothing in that router, so the join is rejected `unauthorized`, and the
  LiveView client responds by falling back to a full page request — with no
  backoff and no attempt cap. The page reloads, rejoins, is rejected again, and
  the preview reload-loops forever roughly once a second.

  No amount of body rewriting fixes that: `<base href>` changes how relative URLs
  resolve, but not what `window.location.href` reports.

  Giving the preview its own origin removes the prefix entirely. The app sees
  `/login`, its router matches, the join is authorized, and cookies, WebSocket
  upgrades and CSP all scope to that host instead of being shared with the
  cockpit.

  ## Host shape

      pv-<port>-<workspace_id>.<domain>

  The port and workspace are encoded in the hostname so the edge router needs no
  registry and no reload when a preview opens or closes — it matches the pattern,
  asks Casein whether this viewer may reach this port, and proxies. See
  `scripts/preview-router.sh` and `CaseinWeb.PreviewAuthzController`.

  Only UUID-shaped workspace ids are eligible: `folder:<base64url>` ids are not
  hostname-safe, and those previews keep using the path proxy.
  """

  @host_prefix "pv"

  # A DNS label caps at 63 characters, and the wildcard certificate covers a
  # single label only. "pv-" + port + "-" + UUID is 45, which leaves room.
  @max_label_length 63

  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc """
  True when preview panes should be served from their own hostname.

  Off by default: it depends on the edge router carrying the `pv-*` route, so it
  stays opt-in until that is deployed. With it off, `Casein.PreviewPanes` keeps
  emitting `/preview-proxy/...` URLs exactly as before.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config() |> Keyword.get(:enabled, false) |> then(&(&1 == true))
  end

  @doc """
  Domain the preview hostnames live under.

  No product default: portable installs leave this unset until the operator
  configures `CASEIN_PREVIEW_DOMAIN` (or the equivalent application env). A
  missing domain keeps own-origin routing disabled via `host/2`.
  """
  @spec domain() :: String.t() | nil
  def domain do
    case Keyword.get(config(), :domain) do
      domain when is_binary(domain) ->
        case String.trim(domain) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Build the preview origin for a workspace's loopback port.

  Returns `:error` when own-origin routing is off, the workspace id is not
  hostname-safe, or the resulting label would exceed the DNS limit — every one of
  which the caller answers by falling back to the path proxy.
  """
  @spec origin(String.t(), pos_integer()) :: {:ok, String.t()} | :error
  def origin(workspace_id, port) do
    with {:ok, host} <- host(workspace_id, port) do
      {:ok, "https://" <> host}
    end
  end

  @doc "Build the preview hostname for a workspace's loopback port."
  @spec host(String.t(), pos_integer()) :: {:ok, String.t()} | :error
  def host(workspace_id, port)
      when is_binary(workspace_id) and is_integer(port) and port > 0 and port < 65_536 do
    domain = domain()

    if enabled?() and is_binary(domain) and hostname_safe_workspace_id?(workspace_id) do
      label = "#{@host_prefix}-#{port}-#{workspace_id}"

      if String.length(label) <= @max_label_length,
        do: {:ok, label <> "." <> domain},
        else: :error
    else
      :error
    end
  end

  def host(_workspace_id, _port), do: :error

  @doc """
  Recover the workspace id and port a preview hostname addresses.

  This is the inverse of `host/2` and the only thing the authorization endpoint
  needs: the hostname is the request's identity, so nothing else has to be
  trusted from the caller. A `:port` suffix (`host:8443`) is tolerated because
  proxies vary in whether they forward one.
  """
  @spec parse_host(String.t()) :: {:ok, %{workspace_id: String.t(), port: pos_integer()}} | :error
  def parse_host(host) when is_binary(host) do
    with [label | _] <- host |> strip_port() |> String.split("."),
         [@host_prefix, port_str, workspace_id] <- String.split(label, "-", parts: 3),
         {port, ""} <- Integer.parse(port_str),
         true <- port > 0 and port < 65_536,
         true <- hostname_safe_workspace_id?(workspace_id) do
      {:ok, %{workspace_id: workspace_id, port: port}}
    else
      _ -> :error
    end
  end

  def parse_host(_host), do: :error

  defp strip_port(host), do: host |> String.split(":") |> List.first() |> to_string()

  # Only canonical UUIDs. `folder:<base64url>` workspace ids contain characters a
  # DNS label cannot carry, and a looser rule would let the "-" split above
  # mis-parse a hostname into the wrong workspace.
  defp hostname_safe_workspace_id?(workspace_id) when is_binary(workspace_id),
    do: Regex.match?(@uuid_pattern, workspace_id)

  defp hostname_safe_workspace_id?(_), do: false

  defp config, do: Application.get_env(:casein, :preview_own_origin, [])
end
