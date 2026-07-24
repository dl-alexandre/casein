defmodule CaseinWeb.HealthController do
  @moduledoc "Product readiness endpoint for operators and container platforms."

  use CaseinWeb, :controller

  def show(conn, _params) do
    opts = Application.get_env(:casein, :readiness_opts, [])
    status = Casein.Readiness.status(opts)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(if(status.ok, do: :ok, else: :service_unavailable))
    |> json(status)
  end
end
