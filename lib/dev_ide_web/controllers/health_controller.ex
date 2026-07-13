defmodule DevIdeWeb.HealthController do
  @moduledoc "Product readiness endpoint for operators and container platforms."

  use DevIdeWeb, :controller

  def show(conn, _params) do
    opts = Application.get_env(:dev_ide, :readiness_opts, [])
    status = DevIDE.Readiness.status(opts)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(if(status.ok, do: :ok, else: :service_unavailable))
    |> json(status)
  end
end
