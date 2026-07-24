defmodule CaseinWeb.Plugs.DesktopAuth do
  @moduledoc """
  Per-install authentication for the loopback desktop cockpit.

  The desktop host opens the cockpit with a short-lived, single-use HMAC claim.
  This plug exchanges that claim for the normal signed, HttpOnly Phoenix
  session and redirects to a clean URL. The per-install root secret never
  enters browser history. A loopback bind is necessary, but is not
  authorization: another local process must not gain terminal access merely by
  reaching the port.
  """

  import Plug.Conn

  @session_key "current_user"
  @desktop_user %{id: "desktop", username: "desktop", email: "desktop@local", role: :user}
  @loopback_hosts MapSet.new(["localhost", "127.0.0.1", "::1"])

  def init(opts), do: opts

  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:casein, :desktop_mode, false)

  def call(conn, _opts) do
    if enabled?() do
      authorize_desktop(conn)
    else
      conn
    end
  end

  defp authorize_desktop(conn) do
    if allowed_host?(conn.host) do
      if conn.request_path == "/healthz" do
        conn
      else
        case get_session(conn, @session_key) do
          @desktop_user -> assign(conn, :current_user, @desktop_user)
          %{"id" => "desktop"} -> assign(conn, :current_user, @desktop_user)
          %{id: "desktop"} -> assign(conn, :current_user, @desktop_user)
          _ -> exchange_launch_token(conn)
        end
      end
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(421, "Desktop Casein only accepts localhost requests")
      |> halt()
    end
  end

  defp exchange_launch_token(%Plug.Conn{method: "GET"} = conn) do
    conn = fetch_query_params(conn)

    case verify_launch_claim(conn) do
      :ok ->
        conn
        |> put_session(@session_key, @desktop_user)
        |> assign(:current_user, @desktop_user)
        |> redirect_to_clean_url()

      :error ->
        reject(conn)
    end
  end

  defp exchange_launch_token(conn), do: reject(conn)

  defp verify_launch_claim(conn) do
    expected = Application.get_env(:casein, :desktop_launch_token)

    case Casein.Desktop.LaunchClaim.verify_and_consume(conn.query_params, expected) do
      :ok -> :ok
      {:error, _reason} -> :error
    end
  end

  defp redirect_to_clean_url(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> Phoenix.Controller.redirect(to: conn.request_path)
    |> halt()
  end

  defp reject(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "Desktop launch token required")
    |> halt()
  end

  defp allowed_host?(host) when is_binary(host) do
    normalized = String.downcase(host)

    MapSet.member?(@loopback_hosts, normalized) or
      normalized in configured_lan_hosts()
  end

  defp allowed_host?(_), do: false

  defp configured_lan_hosts do
    if Application.get_env(:casein, :desktop_lan, false) do
      :casein
      |> Application.get_env(:desktop_lan_hosts, [])
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase/1)
    else
      []
    end
  end
end
