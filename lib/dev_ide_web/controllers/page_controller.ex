defmodule DevIdeWeb.PageController do
  use DevIdeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
