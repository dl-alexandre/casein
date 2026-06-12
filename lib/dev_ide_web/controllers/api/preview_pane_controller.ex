defmodule DevIdeWeb.API.PreviewPaneController do
  @moduledoc """
  Register and deregister preview panes opened by the `devide-preview` CLI.
  """

  use DevIdeWeb, :controller

  alias DevIDE.PreviewPanes

  def create(conn, params) do
    case PreviewPanes.register(params) do
      {:ok, registration} ->
        conn
        |> put_status(:created)
        |> json(%{
          id: registration.id,
          pane_id: registration.pane_id,
          workspace_id: registration.workspace_id,
          preview_id: registration.preview_id,
          control_session_id: registration.control_session_id,
          display_url: registration.display_url,
          url: registration.url,
          viewport: registration.viewport
        })

      {:error, :workspace_not_found} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "workspace_not_found"})

      {:error, :untrusted_url} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "untrusted_url"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def delete(conn, %{"id" => pane_id}) do
    case PreviewPanes.deregister(pane_id) do
      :ok ->
        json(conn, %{status: "removed", pane_id: pane_id})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", pane_id: pane_id})
    end
  end
end
