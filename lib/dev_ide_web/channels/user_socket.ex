defmodule DevIdeWeb.UserSocket do
  use Phoenix.Socket

  channel "terminal:*", DevIdeWeb.TerminalChannel

  @impl true
  def connect(params, socket, _connect_info) do
    case DevIdeWeb.ChannelAuth.verify_user_token(params["token"]) do
      {:ok, user_id} when is_binary(user_id) ->
        # The token carries the authenticated user id (the username under
        # ForwardAuth). Use it rather than the static identity so channels
        # can enforce per-user workspace ownership. Email isn't in the token;
        # channels do DevIDE-side ownership checks, which only need the
        # username.
        user = %{id: user_id, username: user_id, email: nil, role: :owner}
        {:ok, assign(socket, :current_user, user)}

      _ ->
        :error
    end
  end

  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.current_user.id}"
end
