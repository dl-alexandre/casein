defmodule DevIdeWeb.API.TerminalSmokeController do
  @moduledoc """
  Internal post-deploy terminal acceptance smoke.

  `GET /api/smoke/terminal` opens a throwaway terminal against this running
  release and asserts it is usable (tmux server cwd live, pane starts in a real
  directory). 200 `{ok: true}` / 503 `{ok: false, ...}`. Internal-only (unix
  socket + `ApiAuth`); the deploy script gates promotion on it.
  """

  use DevIdeWeb, :controller

  def show(conn, _params) do
    case DevIDE.Deployment.TerminalSmoke.run() do
      :ok ->
        conn |> put_status(200) |> json(%{ok: true})

      {:error, reason} ->
        conn |> put_status(503) |> json(%{ok: false, reason: inspect(reason)})
    end
  end
end
