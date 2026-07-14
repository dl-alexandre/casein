defmodule DevIdeWeb.Plugs.DesktopAuth do
  @moduledoc """
  Per-install authentication for the loopback desktop cockpit.

  The Windows host opens the cockpit with an unguessable per-install launch token.
  This plug exchanges that token for the normal signed, HttpOnly Phoenix session
  and redirects to a clean URL. Subsequent browser and LiveView requests use
  that session. A loopback bind is necessary, but is not authorization: another
  local process must not gain terminal access merely by reaching the port.
  """

  import Plug.Conn

  @session_key "current_user"
  @token_param "desktop_token"
  @desktop_user %{id: "desktop", username: "desktop", email: "desktop@local", role: :user}
  @allowed_hosts MapSet.new(["localhost", "127.0.0.1", "::1"])

  def init(opts), do: opts

  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:dev_ide, :desktop_mode, false)

  def call(conn, _opts) do
    if enabled?() do
      authorize_desktop(conn)
    else
      conn
    end
  end

  defp authorize_desktop(conn) do
    if allowed_host?(conn.host) do
      case get_session(conn, @session_key) do
        @desktop_user -> assign(conn, :current_user, @desktop_user)
        %{"id" => "desktop"} -> assign(conn, :current_user, @desktop_user)
        %{id: "desktop"} -> assign(conn, :current_user, @desktop_user)
        _ -> exchange_launch_token(conn)
      end
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(421, "Desktop DevIDE only accepts localhost requests")
      |> halt()
    end
  end

  defp exchange_launch_token(%Plug.Conn{method: "GET"} = conn) do
    conn = fetch_query_params(conn)

    case fetch_query_token(conn) do
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

  defp fetch_query_token(conn) do
    expected = Application.get_env(:dev_ide, :desktop_launch_token)
    supplied = conn.query_params[@token_param]

    if is_binary(expected) and byte_size(expected) >= 32 and is_binary(supplied) and
         byte_size(supplied) == byte_size(expected) and Plug.Crypto.secure_compare(supplied, expected) do
      :ok
    else
      :error
    end
  end

  defp redirect_to_clean_url(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> redirect(external: conn.request_path)
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
    MapSet.member?(@allowed_hosts, String.downcase(host))
  end

  defp allowed_host?(_), do: false
end
