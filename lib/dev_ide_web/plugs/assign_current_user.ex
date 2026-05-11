defmodule DevIdeWeb.Plugs.AssignCurrentUser do
  @moduledoc """
  Single-user dev identity boundary.

  M1.5 placeholder. Assigns a static `:current_user` so downstream code
  (terminal session naming, ownership) can depend on the seam without
  pulling in `phx.gen.auth` yet.
  """

  import Plug.Conn

  @default %{id: "dev", email: "dev@local", role: :owner}

  def init(opts), do: opts

  def call(conn, _opts), do: assign(conn, :current_user, current_user())

  def current_user, do: Application.get_env(:dev_ide, :current_user, @default)

  @doc "Lookup the current user from a LiveView session map."
  def from_session(_session), do: current_user()
end
