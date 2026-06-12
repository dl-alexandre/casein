defmodule DevIdeWeb.API.DeployStatusController do
  @moduledoc "Internal deploy handoff health endpoint."

  use DevIdeWeb, :controller

  def show(conn, _params) do
    opts = Application.get_env(:dev_ide, :deployment_health_opts, [])
    status = DevIDE.Deployment.Health.status(opts)

    conn
    |> put_status(if(status.ok, do: 200, else: 503))
    |> json(status)
  end
end
