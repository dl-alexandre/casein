defmodule DevIdeWeb.PageController do
  @moduledoc "Root landing controller; redirects `GET /` to the workspace index."
  use DevIdeWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/workspaces")
  end
end
