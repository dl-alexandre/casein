defmodule CaseinWeb.SocketCredentialPolicyTest do
  use Casein.DataCase, async: false

  import Phoenix.ChannelTest

  alias Casein.DeviceLinks
  alias Casein.Workspace

  alias CaseinWeb.{
    ChannelAuth,
    MobileTerminalChannel,
    SocketCredentialPolicy,
    TerminalChannel,
    UserSocket
  }

  @endpoint CaseinWeb.Endpoint

  defmodule OwnedSource do
    def get(id, _auth) do
      if pid = Application.get_env(:casein, :socket_credential_policy_test_pid),
        do: send(pid, {:workspace_lookup, id})

      {:ok, %Workspace{id: id, name: id, user: "owner", status: :running}}
    end
  end

  setup do
    previous_source = Application.get_env(:casein, :workspace_source)
    previous_test_pid = Application.get_env(:casein, :socket_credential_policy_test_pid)
    Application.put_env(:casein, :workspace_source, OwnedSource)
    Application.put_env(:casein, :socket_credential_policy_test_pid, self())

    on_exit(fn ->
      if is_nil(previous_source),
        do: Application.delete_env(:casein, :workspace_source),
        else: Application.put_env(:casein, :workspace_source, previous_source)

      if is_nil(previous_test_pid),
        do: Application.delete_env(:casein, :socket_credential_policy_test_pid),
        else: Application.put_env(:casein, :socket_credential_policy_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "pairing credential cannot join an ordinary terminal topic" do
    token =
      ChannelAuth.sign_pairing_token(
        %{id: "owner", email: "owner@example.com", role: :owner},
        "ws-1"
      )

    assert {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => token})
    assert socket.assigns.socket_credential == :pairing_token
    drain_workspace_lookups()

    assert {:error, %{reason: "terminal access is not authorized"}} =
             subscribe_and_join(socket, TerminalChannel, "terminal:ws-1:workspace", %{})

    assert_no_terminal_side_effects("ws-1", "workspace")
  end

  test "durable device-link credential cannot join an ordinary terminal topic" do
    assert {:ok, %{token: token}} =
             DeviceLinks.create_from_pairing_claims(%{
               id: "owner",
               username: "owner",
               email: "owner@example.com",
               role: :owner,
               workspace_id: "ws-1"
             })

    assert {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => token})
    assert socket.assigns.socket_credential == :device_link_token
    drain_workspace_lookups()

    assert {:error, %{reason: "terminal access is not authorized"}} =
             subscribe_and_join(socket, TerminalChannel, "terminal:ws-1:workspace", %{})

    assert_no_terminal_side_effects("ws-1", "workspace")
  end

  test "mobile terminal route requires separate verified child-grant admission" do
    assert {MobileTerminalChannel, []} = UserSocket.__channel__("mobile_terminal:lease-1")

    for assigns <- [
          %{socket_credential: :pairing_token, pairing_workspace_id: "ws-1"},
          %{socket_credential: :device_link_token, pairing_workspace_id: "ws-1"},
          %{}
        ] do
      assert {:error, :terminal_child_grant_required} =
               SocketCredentialPolicy.authorize_mobile_terminal(assigns)
    end
  end

  test "mobile-scoped legacy sockets are denied ordinary terminal admission" do
    assert {:error, :terminal_access_denied} =
             SocketCredentialPolicy.authorize_ordinary_terminal(%{
               current_user: %{id: "owner"},
               pairing_workspace_id: "ws-1"
             })
  end

  test "browser user credential retains ordinary terminal admission" do
    assert :ok =
             SocketCredentialPolicy.authorize_ordinary_terminal(%{
               socket_credential: :user_token,
               current_user: %{id: "owner"}
             })
  end

  test "unknown credential classes fail closed" do
    assert {:error, :terminal_access_denied} =
             SocketCredentialPolicy.authorize_ordinary_terminal(%{
               socket_credential: :unknown_future_credential,
               current_user: %{id: "owner"}
             })
  end

  test "missing credential marker fails closed" do
    assert {:error, :terminal_access_denied} =
             SocketCredentialPolicy.authorize_ordinary_terminal(%{
               current_user: %{id: "owner"}
             })
  end

  defp assert_no_terminal_side_effects(workspace_id, sid) do
    refute_receive {:workspace_lookup, ^workspace_id}

    assert Registry.lookup(
             Casein.Terminals.Registry,
             {:terminal_owner, :shell, workspace_id, sid}
           ) == []

    assert Registry.lookup(Casein.Terminals.Registry, {workspace_id, sid}) == []
  end

  defp drain_workspace_lookups do
    receive do
      {:workspace_lookup, _workspace_id} -> drain_workspace_lookups()
    after
      0 -> :ok
    end
  end
end
