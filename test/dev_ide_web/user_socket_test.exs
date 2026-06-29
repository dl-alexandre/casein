defmodule DevIdeWeb.UserSocketTest do
  use ExUnit.Case, async: false

  alias DevIdeWeb.{ChannelAuth, UserSocket}

  test "connect assigns current_user from a signed token" do
    token = ChannelAuth.sign_user_token("user-1", "user@example.com")

    assert {:ok, socket} = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})

    assert socket.assigns.current_user == %{
             id: "user-1",
             username: "user-1",
             email: "user@example.com",
             role: :owner
           }
  end

  test "connect accepts legacy tokens that sign only the user id" do
    token = Phoenix.Token.sign(DevIdeWeb.Endpoint, "user socket", "legacy-user")

    assert {:ok, socket} = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})

    assert socket.assigns.current_user.id == "legacy-user"
    assert socket.assigns.current_user.email == nil
  end

  test "connect rejects missing or invalid tokens" do
    assert :error = UserSocket.connect(%{}, %Phoenix.Socket{}, %{})
    assert :error = UserSocket.connect(%{"token" => ""}, %Phoenix.Socket{}, %{})
    assert :error = UserSocket.connect(%{"token" => "not-a-real-token"}, %Phoenix.Socket{}, %{})
  end

  test "id/1 returns a stable users_socket identifier" do
    socket = %Phoenix.Socket{assigns: %{current_user: %{id: "user-42"}}}

    assert UserSocket.id(socket) == "users_socket:user-42"
  end
end
