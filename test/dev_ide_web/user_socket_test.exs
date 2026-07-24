defmodule CaseinWeb.UserSocketTest do
  use Casein.DataCase, async: false

  alias Casein.DeviceLinks
  alias Casein.Workspace
  alias CaseinWeb.{ChannelAuth, UserSocket}

  defmodule OwnedSource do
    def get(id, _auth), do: {:ok, %Workspace{id: id, name: id, user: "owner", status: :running}}
  end

  setup do
    prev_source = Application.get_env(:dev_ide, :workspace_source)
    Application.put_env(:dev_ide, :workspace_source, OwnedSource)

    on_exit(fn -> restore(:workspace_source, prev_source) end)

    :ok
  end

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
    token = Phoenix.Token.sign(CaseinWeb.Endpoint, "user socket", "legacy-user")

    assert {:ok, socket} = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})

    assert socket.assigns.current_user.id == "legacy-user"
    assert socket.assigns.current_user.email == nil
  end

  test "connect rejects missing or invalid tokens" do
    assert :error = UserSocket.connect(%{}, %Phoenix.Socket{}, %{})
    assert :error = UserSocket.connect(%{"token" => ""}, %Phoenix.Socket{}, %{})
    assert :error = UserSocket.connect(%{"token" => "not-a-real-token"}, %Phoenix.Socket{}, %{})
  end

  test "connect accepts persistent device link tokens" do
    assert {:ok, %{token: token, link: link}} =
             DeviceLinks.create_from_pairing_claims(
               %{
                 id: "owner",
                 username: "owner",
                 email: "owner@example.com",
                 role: :owner,
                 workspace_id: "ws-1"
               },
               %{platform: "ios"}
             )

    assert {:ok, socket} = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})

    assert socket.assigns.current_user == %{
             id: "owner",
             username: "owner",
             email: "owner@example.com",
             role: :owner
           }

    assert socket.assigns.pairing_workspace_id == "ws-1"
    assert socket.assigns.device_link_id == link.id
    # Device provenance is available to the action dispatcher from connect.
    assert socket.assigns.mobile_platform == "ios"
  end

  test "id/1 returns a stable users_socket identifier" do
    socket = %Phoenix.Socket{assigns: %{current_user: %{id: "user-42"}}}

    assert UserSocket.id(socket) == "users_socket:user-42"
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)
end
