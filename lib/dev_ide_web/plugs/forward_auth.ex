defmodule CaseinWeb.Plugs.ForwardAuth do
  @moduledoc """
  Trusted-header identity for forward-auth deployments.

  When Casein runs behind an authenticating reverse proxy
  (e.g. Caddy + oauth2-proxy), the proxy sets `X-Auth-Request-Email` on
  every upstream request. This plug reads that header, derives the
  workspace username (`email |> split("@") |> hd |> downcase`), assigns
  `:current_user`, and stashes it in the session so LiveView mounts
  (`AssignCurrentUser.from_session/1`) see the same identity.

  Enabled via `:casein, :forward_auth` (or env `DEV_IDE_FORWARD_AUTH`).
  When enabled, a request missing the header is rejected with 401 — the
  proxy should have caught unauthenticated requests already. When
  disabled, falls back to the static `AssignCurrentUser` identity so
  local single-user dev is unaffected.

  SECURITY: the header is only trustworthy because the proxy strips any
  client-supplied copy and re-sets it from its authenticator. Casein
  must bind to localhost / the internal bridge so it is unreachable
  except through the proxy — otherwise a client could spoof the header
  directly.

  Trust-chain verification (checked against the live devbox Caddyfile,
  2026-06-10): the `(forward_auth)` snippet sends every request to
  oauth2-proxy's `/oauth2/auth` and `copy_headers X-Auth-Request-User
  X-Auth-Request-Email` overwrites those request headers from the auth
  response on every authenticated request, so a client-supplied copy
  cannot survive an authenticated path. Two matcher exclusions bypass
  forward-auth entirely — `OPTIONS` requests and `/site.webmanifest` —
  and on those paths a client-supplied header would pass through
  unmodified. `/site.webmanifest` is static. OPTIONS is more subtle:
  Caddy skips oauth2-proxy for OPTIONS, but the Phoenix router still has
  a `match :*` preview-proxy catch-all that accepts OPTIONS. Trusting a
  client-supplied `X-Auth-Request-Email` on OPTIONS would let an attacker
  spoof identity and proxy a victim's loopback server. This plug therefore
  rejects all OPTIONS with 405 and never reads the header on that method.
  GET/POST (and other authenticated methods) remain trusted because Caddy
  resets the header from oauth2-proxy on those paths. CORS preflight for
  embedded apps is not required through this path: preview-proxy content
  is same-origin to the iframe, so browsers do not preflight those loads.
  """

  import Plug.Conn

  alias CaseinWeb.Plugs.AssignCurrentUser
  alias CaseinWeb.Plugs.DesktopAuth

  @session_key "current_user"

  def init(opts), do: opts

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    # Never trust client-supplied identity on OPTIONS (Caddy bypasses
    # oauth2-proxy for preflight; the preview-proxy catch-all would otherwise
    # accept a spoofed X-Auth-Request-Email).
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(405, "Method Not Allowed")
    |> halt()
  end

  def call(conn, _opts) do
    cond do
      DesktopAuth.enabled?() ->
        DesktopAuth.call(conn, [])

      enabled?() ->
        case get_req_header(conn, "x-auth-request-email") do
          [email | _] when is_binary(email) and email != "" ->
            put_user(conn, user_from_email(email))

          _ ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(401, "Not authenticated")
            |> halt()
        end

      true ->
        # Local dev / no proxy: keep the static single-user identity, but still
        # write it to the session so `from_session/1` has one consistent source.
        put_user(conn, AssignCurrentUser.current_user())
    end
  end

  @doc """
  Derive the identity from a forward-auth email. The username is the
  email's local part, lowercased.

  Every authenticated viewer gets the same role (`:user`). There is no
  elevated admin tier — peers are equal once oauth2-proxy has authenticated
  them. See `Workspaces.viewer_can_access_workspace?/2`.
  """
  @spec user_from_email(String.t()) :: map()
  def user_from_email(email) when is_binary(email) do
    email = String.downcase(email)
    username = email |> String.split("@") |> hd()

    %{id: username, username: username, email: email, role: :user}
  end

  @doc """
  Legacy `DEV_IDE_ADMINS` / `:admins` list parser.

  **No longer grants privileges.** Kept so existing env still loads without
  error and so `runtime.exs` can treat a non-empty value as a signal that
  forward-auth is intended. New deploys should set `DEV_IDE_FORWARD_AUTH=true`
  and omit `DEV_IDE_ADMINS`.
  """
  @spec admins() :: [String.t()]
  def admins do
    case Application.get_env(:casein, :admins) do
      list when is_list(list) ->
        Enum.map(list, &String.downcase/1)

      _ ->
        case System.get_env("DEV_IDE_ADMINS") do
          nil -> []
          str -> str |> String.split([",", " "], trim: true) |> Enum.map(&String.downcase/1)
        end
    end
  end

  @doc """
  Historical "is this viewer unrestricted?" check.

  Always true for any authenticated identity map so call sites that still
  gate UI (browse restrictions, device stats, session rail) never create a
  second privilege tier. Requires a non-empty id/username/email (same rule as
  workspace access). False for nil, non-maps, or empty maps.
  """
  @spec admin?(map() | any()) :: boolean()
  def admin?(%{} = viewer) do
    email = Map.get(viewer, :email) || Map.get(viewer, "email")
    id = Map.get(viewer, :id) || Map.get(viewer, "id")
    username = Map.get(viewer, :username) || Map.get(viewer, "username")

    Enum.any?([email, id, username], fn
      v when is_binary(v) -> String.trim(v) != ""
      _ -> false
    end)
  end

  def admin?(_), do: false

  @doc "True when forward-auth header trust is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:casein, :forward_auth) do
      nil -> System.get_env("DEV_IDE_FORWARD_AUTH") in ~w(1 true yes)
      val -> !!val
    end
  end

  @doc """
  Asserts the HTTP listener is loopback- or unix-socket-bound when forward-auth
  is enabled. Raises on misconfiguration in every environment (fail closed).
  """
  @spec assert_safe_listener_bind!() :: :ok
  def assert_safe_listener_bind! do
    if enabled?() and not listener_bind_safe?() do
      raise bind_unsafe_message(endpoint_bind_ip())
    end

    :ok
  end

  @doc false
  @spec listener_bind_safe?() :: boolean()
  def listener_bind_safe? do
    loopback_or_socket_ip?(endpoint_bind_ip())
  end

  defp bind_unsafe_message(ip) do
    "Forward-auth is enabled (Casein trusts X-Auth-Request-Email) but the HTTP " <>
      "listener is bound to #{inspect(ip)}, not loopback/unix-socket — a client " <>
      "that reaches this port directly can spoof identity. Bind 127.0.0.1, ::1, " <>
      "or a unix socket behind the proxy. (audit #10 / F3)"
  end

  defp loopback_or_socket_ip?({127, 0, 0, 1}), do: true
  defp loopback_or_socket_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_or_socket_ip?({:local, _}), do: true
  # No explicit bind configured (e.g. server not started): nothing to assert.
  defp loopback_or_socket_ip?(nil), do: true
  defp loopback_or_socket_ip?(_), do: false

  defp endpoint_bind_ip do
    Application.get_env(:casein, CaseinWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:ip)
  end

  defp put_user(conn, user) do
    conn
    |> assign(:current_user, user)
    |> put_session(@session_key, user)
  end
end
