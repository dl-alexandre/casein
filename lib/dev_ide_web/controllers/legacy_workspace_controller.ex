defmodule DevIdeWeb.LegacyWorkspaceController do
  @moduledoc """
  Legacy picker URL. The `/workspaces` index is absorbed by the dashboard at
  `/` (path-first navigation Stage 3); this keeps old links and bookmarks
  working. `/workspaces/:id` routes stay live for opaque-id workspace access.

  `/workspaces/:id/previous-sessions` is absorbed by the cockpit's History
  side panel: it redirects to the workspace's canonical URL with the
  `tab=history` deep-link param, preserving any search query params the old
  page accepted. Viewer access is enforced by the cockpit mount, not here.

  `/notifications` is absorbed by the in-viewer notifications drawer: it
  redirects to the dashboard with the `drawer=notifications` deep-link param.
  Notifications stay scoped to the mounted viewer inside the drawer.
  """

  use DevIdeWeb, :controller

  alias DevIdeWeb.WorkspaceRoutes

  def index(conn, _params) do
    redirect(conn, to: ~p"/")
  end

  def notifications(conn, _params) do
    redirect(conn, to: ~p"/?drawer=notifications")
  end

  def previous_sessions(conn, %{"id" => id} = params) do
    query =
      params
      |> Map.delete("id")
      |> Map.put("tab", "history")
      |> URI.encode_query()

    redirect(conn, to: WorkspaceRoutes.workspace_path(id) <> "?" <> query)
  end
end
