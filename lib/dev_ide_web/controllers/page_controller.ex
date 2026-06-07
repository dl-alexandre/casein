defmodule DevIdeWeb.PageController do
  use DevIdeWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/workspaces")
  end
end
