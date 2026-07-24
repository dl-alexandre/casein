defmodule CaseinWeb.Plugs.AssignCurrentUser do
  @moduledoc """
  Identity seam for downstream code (terminal session naming, ownership).

  In forward-auth deployments `CaseinWeb.Plugs.ForwardAuth` is the request
  plug — it derives identity from `X-Auth-Request-Email` and writes it to the
  session. This module retains the static-user fallback for local
  single-user dev and the `from_session/1` reader LiveView mounts use.

  `current_user/0` is the static fallback identity, used when forward-auth is
  disabled (and by code paths without a session, e.g. the socket).
  """

  import Plug.Conn

  @default %{id: "dev", username: "dev", email: "dev@local", role: :user}

  def init(opts), do: opts

  def call(conn, _opts), do: assign(conn, :current_user, current_user())

  def current_user, do: Application.get_env(:casein, :current_user, @default)

  @doc """
  Look up the current user from a LiveView session map.

  Reads the identity `ForwardAuth` stashed in the session; falls back to the
  static `current_user/0` when absent (no session entry yet, or forward-auth
  disabled and the request didn't pass through a plug that set it).
  """
  def from_session(%{"current_user" => %{} = user}), do: user
  def from_session(_session), do: current_user()
end
