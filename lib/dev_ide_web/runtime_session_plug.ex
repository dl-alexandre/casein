defmodule DevIdeWeb.RuntimeSessionPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    DevIdeWeb.SessionOptions.options()
    |> Plug.Session.init()
    |> then(&Plug.Session.call(conn, &1))
  end
end
