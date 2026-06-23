defmodule DevIdeWeb.UserSocket do
  @moduledoc """
  Phoenix socket for the browser terminal stream. Verifies the signed user
  token (`ChannelAuth.verify_user_token/1`) on connect, assigns `:current_user`,
  and routes `terminal:*` topics to `DevIdeWeb.TerminalChannel`.
  """
  use Phoenix.Socket

  channel "terminal:*", DevIdeWeb.TerminalChannel

  @impl true
  def connect(params, socket, _connect_info) do
    case DevIdeWeb.ChannelAuth.verify_user_token(params["token"]) do
      {:ok, user_id, email} when is_binary(user_id) ->
        # The token carries the authenticated user id + email. Email is
        # needed because channels forward auth to the workspace source
        # (Workspaces.get/2 etc.) using `x-auth-request-email` — without
        # it, the source rejects unauthenticated lookups and channel
        # joins refuse.
        user = %{id: user_id, username: user_id, email: email, role: :owner}
        {:ok, assign(socket, :current_user, user)}

      _ ->
        :error
    end
  end

  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.current_user.id}"
end
