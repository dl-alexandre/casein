defmodule CaseinWeb.PreviewAuthzController do
  @moduledoc """
  Authorization sub-request for own-origin previews.

  The edge router (`scripts/preview-router.sh`) serves `pv-<port>-<workspace>`
  hostnames straight through to `127.0.0.1:<port>`. Being logged in is not enough
  to allow that: the identity check in front of it only proves *someone* from the
  company is signed in, while the loopback ports behind it are other people's dev
  servers. So before proxying, the router forward-auths here, and this endpoint
  applies the same gate the path proxy applies — `Casein.Previews.Access`.

  The request's own hostname is the subject of the decision, so nothing else has
  to be trusted from the caller: a client cannot ask about a port other than the
  one it is already being routed to.

  Answers `204` to allow and `403` to deny. It never returns a body — the router
  only reads the status.
  """
  use CaseinWeb, :controller

  alias Casein.Previews.Access
  alias Casein.Previews.OwnOrigin

  @spec authz(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authz(conn, _params) do
    with {:ok, %{workspace_id: workspace_id, port: port}} <- parse_target(conn),
         {:ok, _workspace} <- Access.authorize(conn.assigns[:current_user], workspace_id, port) do
      send_resp(conn, 204, "")
    else
      _ -> send_resp(conn, 403, "")
    end
  end

  # The router preserves the browser's Host; `x-forwarded-host` is honoured first
  # because proxies differ in which one they rewrite. Both are set by the edge,
  # not the client: a spoofed value only changes which port the *caller's own*
  # access is evaluated against, and that evaluation still has to pass.
  defp parse_target(conn) do
    conn
    |> candidate_hosts()
    |> Enum.find_value(:error, fn host ->
      case OwnOrigin.parse_host(host) do
        {:ok, target} -> {:ok, target}
        :error -> nil
      end
    end)
  end

  defp candidate_hosts(conn) do
    forwarded = Plug.Conn.get_req_header(conn, "x-forwarded-host")
    host = Plug.Conn.get_req_header(conn, "host")

    (forwarded ++ host ++ [conn.host])
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
  end
end
