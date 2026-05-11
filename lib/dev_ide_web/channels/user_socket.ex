defmodule DevIdeWeb.UserSocket do
  use Phoenix.Socket

  channel "terminal:*", DevIdeWeb.TerminalChannel

  @impl true
  def connect(params, socket, _connect_info) do
    case DevIdeWeb.ChannelAuth.verify_user_token(params["token"]) do
      {:ok, _user_id} ->
        user = DevIdeWeb.Plugs.AssignCurrentUser.current_user()
        {:ok, assign(socket, :current_user, user)}

      _ ->
        :error
    end
  end

  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.current_user.id}"
end
