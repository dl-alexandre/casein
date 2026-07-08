defmodule DevIdeWeb.Plugs.ForwardAuth do
  @moduledoc """
  Trusted-header identity for forward-auth deployments.

  When DevIDE runs behind an authenticating reverse proxy
  (e.g. Caddy + oauth2-proxy), the proxy sets `X-Auth-Request-Email` on
  every upstream request. This plug reads that header, derives the
  workspace username (`email |> split("@") |> hd |> downcase`), assigns
  `:current_user`, and stashes it in the session so LiveView mounts
  (`AssignCurrentUser.from_session/1`) see the same identity.

  Enabled via `:dev_ide, :forward_auth` (or env `DEV_IDE_FORWARD_AUTH`).
  When enabled, a request missing the header is rejected with 401 — the
  proxy should have caught unauthenticated requests already. When
  disabled, falls back to the static `AssignCurrentUser` identity so
  local single-user dev is unaffected.

  SECURITY: the header is only trustworthy because the proxy strips any
  client-supplied copy and re-sets it from its authenticator. DevIDE
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
  unmodified. This is acceptable today because the Phoenix router
  defines no OPTIONS routes (unmatched OPTIONS → 404 before this plug
  could be trusted with anything), and `/site.webmanifest` is static.
  If an OPTIONS-routable endpoint is ever added behind the `:browser`
  pipeline, the Caddy matcher must be revisited first.
  """

  import Plug.Conn

  alias DevIdeWeb.Plugs.AssignCurrentUser

  @session_key "current_user"

  def init(opts), do: opts

  def call(conn, _opts) do
    if enabled?() do
      case get_req_header(conn, "x-auth-request-email") do
        [email | _] when is_binary(email) and email != "" ->
          put_user(conn, user_from_email(email))

        _ ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(401, "Not authenticated")
          |> halt()
      end
    else
      # Local dev / no proxy: keep the static single-user identity, but still
      # write it to the session so `from_session/1` has one consistent source.
      put_user(conn, AssignCurrentUser.current_user())
    end
  end

  @doc """
  Derive the identity from a forward-auth email. The username is the
  email's local part, lowercased.

  The `:role` is `:admin` when the email is in the configured `admins/0`
  list (cross-user workspace visibility), otherwise `:owner`.
  """
  @spec user_from_email(String.t()) :: map()
  def user_from_email(email) when is_binary(email) do
    email = String.downcase(email)
    username = email |> String.split("@") |> hd()
    role = if email in admins(), do: :admin, else: :owner

    %{id: username, username: username, email: email, role: role}
  end

  @doc """
  Lowercased admin emails. Admins get cross-user workspace visibility.
  Set via `:dev_ide, :admins` (list) or env `DEV_IDE_ADMINS`
  (comma/space separated).
  """
  @spec admins() :: [String.t()]
  def admins do
    case Application.get_env(:dev_ide, :admins) do
      list when is_list(list) ->
        Enum.map(list, &String.downcase/1)

      _ ->
        case System.get_env("DEV_IDE_ADMINS") do
          nil -> []
          str -> str |> String.split([",", " "], trim: true) |> Enum.map(&String.downcase/1)
        end
    end
  end

  @doc "True when the identity carries the admin role."
  @spec admin?(map() | any()) :: boolean()
  def admin?(%{role: :admin}), do: true
  def admin?(_), do: false

  @doc "True when forward-auth header trust is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:dev_ide, :forward_auth) do
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
    "Forward-auth is enabled (DevIDE trusts X-Auth-Request-Email) but the HTTP " <>
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
    Application.get_env(:dev_ide, DevIdeWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:ip)
  end

  defp put_user(conn, user) do
    conn
    |> assign(:current_user, user)
    |> put_session(@session_key, user)
  end
end
