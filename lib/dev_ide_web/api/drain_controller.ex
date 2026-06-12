defmodule DevIdeWeb.API.DrainController do
  @moduledoc "Internal API endpoint for initiating a graceful deployment drain."

  use DevIdeWeb, :controller

  def drain(conn, params) do
    commits_behind = params |> Map.get("commits_behind", 0) |> parse_int()

    case DevIDE.Deployment.Drain.start_drain(commits_behind) do
      :ok ->
        json(conn, %{ok: true})

      {:error, :already_draining} ->
        conn |> put_status(409) |> json(%{error: "already_draining"})
    end
  end

  defp parse_int(n) when is_integer(n), do: max(n, 0)
  defp parse_int(s) when is_binary(s), do: s |> Integer.parse() |> elem(0) |> max(0)
  defp parse_int(_), do: 0
end
