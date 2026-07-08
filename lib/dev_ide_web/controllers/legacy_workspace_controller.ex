defmodule DevIdeWeb.LegacyWorkspaceController do
  @moduledoc """
  Legacy URL redirects into the cockpit shell.

  `/workspaces` → `/` (scratch cockpit; listing is the SESSIONS sidebar).
  `/notifications` → `/?drawer=notifications` (in-viewer notifications drawer).
  `/workspaces/:id/previous-sessions` → cockpit History panel (`?tab=history`).

  Viewer access is enforced by the cockpit mount, not here.
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
