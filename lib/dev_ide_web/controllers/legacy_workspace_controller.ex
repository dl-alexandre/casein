defmodule DevIdeWeb.LegacyWorkspaceController do
  @moduledoc """
  Legacy picker URL. The `/workspaces` index is absorbed by the dashboard at
  `/` (path-first navigation Stage 3); this keeps old links and bookmarks
  working. `/workspaces/:id` routes stay live for opaque-id workspace access.
  """

  use DevIdeWeb, :controller

  def index(conn, _params) do
    redirect(conn, to: ~p"/")
  end
end
