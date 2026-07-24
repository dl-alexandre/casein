defmodule CaseinWeb.DesktopHealthController do
  @moduledoc """
  Loopback readiness probe for the desktop host (menu bar extra).

  Unauthenticated by design: the desktop profile binds loopback-only and
  the host polls before any session exists. Outside the desktop profile
  the route answers 404 so no version metadata leaks from networked
  deployments. See `docs/desktop/platform_architecture.md`.
  """

  use CaseinWeb, :controller

  def show(conn, _params) do
    if Application.get_env(:casein, :desktop_mode, false) do
      {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)

      base =
        case Casein.Desktop.Status.current() do
          %{} = payload -> Map.take(payload, ~w(status version revision port base_url))
          nil -> %{"status" => "ready"}
        end

      json(conn, Map.put(base, "uptime_ms", uptime_ms))
    else
      send_resp(conn, 404, "Not Found")
    end
  end
end
