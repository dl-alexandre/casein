defmodule DevIdeWeb.API.DeployStatusController do
  @moduledoc "Internal deploy handoff health endpoint."

  use DevIdeWeb, :controller

  def show(conn, _params) do
    status = DevIDE.Deployment.Health.status()

    conn
    |> put_status(if(status.ok, do: 200, else: 503))
    |> json(status)
  end
end
