defmodule CaseinWeb.API.SuperadminHandoffController do
  @moduledoc "Browser handoff and forward-auth bridge for the OneBackend superadmin shell."

  use CaseinWeb, :controller

  alias Casein.Workspaces
  alias CaseinWeb.Plugs.ForwardAuth
  alias CaseinWeb.SuperadminHandoff

  @session_key "current_user"

  @spec exchange(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def exchange(conn, %{"token" => token}) do
    with {:ok, claims} <- SuperadminHandoff.verify(token),
         {:ok, workspace} <- Workspaces.get(claims["workspace_id"]),
         user <- ForwardAuth.user_from_email(claims["email"]),
         true <- Workspaces.viewer_can_access_workspace?(workspace, user) do
      conn
      |> put_session(@session_key, user)
      |> put_session("superadmin_handoff", true)
      |> redirect(to: workspace_path(claims))
    else
      _ -> unauthorized(conn)
    end
  end

  def exchange(conn, _), do: unauthorized(conn)

  @spec authz(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authz(conn, _params) do
    case get_session(conn, @session_key) do
      %{email: email} when is_binary(email) and email != "" ->
        conn
        |> put_resp_header("x-auth-request-email", email)
        |> send_resp(204, "")

      %{"email" => email} when is_binary(email) and email != "" ->
        conn
        |> put_resp_header("x-auth-request-email", email)
        |> send_resp(204, "")

      _ ->
        unauthorized(conn)
    end
  end

  defp workspace_path(claims) do
    "/workspaces/" <>
      URI.encode_www_form(claims["workspace_id"]) <>
      "?" <>
      URI.encode_query(%{
        "session" => claims["session_id"],
        "surface" => "terminal",
        "tmux_session" => claims["tmux_session"]
      })
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "Not authenticated")
    |> halt()
  end
end
