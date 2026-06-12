defmodule DevIdeWeb.API.DrainController do
  @moduledoc "Internal API endpoint for initiating a graceful deployment drain."

  use DevIdeWeb, :controller

  def drain(conn, _params) do
    case DevIDE.Deployment.Drain.start_drain() do
      :ok ->
        json(conn, %{ok: true})

      {:error, :already_draining} ->
        conn |> put_status(409) |> json(%{error: "already_draining"})
    end
  end
end
