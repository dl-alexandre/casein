defmodule DevIdeWeb.UserSocket do
  @moduledoc """
  Phoenix socket for the browser terminal stream. Verifies the signed user
  token (`ChannelAuth.verify_user_token/1`) on connect, assigns `:current_user`,
  and routes `terminal:*` topics to `DevIdeWeb.TerminalChannel` and
  `session:*` / `mobile:user:*` topics to the mobile companion channels.
  """
  use Phoenix.Socket

  channel "terminal:*", DevIdeWeb.TerminalChannel
  channel "session:*", DevIdeWeb.SessionChannel
  channel "mobile:user:*", DevIdeWeb.MobileUserChannel

  @impl true
  def connect(params, socket, _connect_info) do
    token = params["token"]

    case DevIdeWeb.ChannelAuth.verify_user_token(token) do
      {:ok, user_id, email} when is_binary(user_id) ->
        # The token carries the authenticated user id + email. Email is
        # needed because channels forward auth to the workspace source
        # (Workspaces.get/2 etc.) using `x-auth-request-email` — without
        # it, the source rejects unauthenticated lookups and channel
        # joins refuse.
        user = %{id: user_id, username: user_id, email: email, role: :owner}
        {:ok, assign(socket, :current_user, user)}

      _ ->
        connect_pairing_token(token, socket)
    end
  end

  defp connect_pairing_token(token, socket) do
    case DevIdeWeb.ChannelAuth.verify_pairing_token(token) do
      {:ok, %{workspace_id: workspace_id} = claims} ->
        user = Map.take(claims, [:id, :username, :email, :role])

        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:pairing_workspace_id, workspace_id)}

      _ ->
        :error
    end
  end

  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.current_user.id}"
end
