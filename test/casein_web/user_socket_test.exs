defmodule CaseinWeb.UserSocketTest do
  use Casein.DataCase, async: false

  alias Casein.DeviceLinks
  alias Casein.Mobile.FeedTiming
  alias Casein.Workspace
  alias CaseinWeb.{ChannelAuth, UserSocket}

  defmodule OwnedSource do
    def get(id, _auth), do: {:ok, %Workspace{id: id, name: id, user: "owner", status: :running}}
  end

  setup do
    prev_source = Application.get_env(:casein, :workspace_source)
    Application.put_env(:casein, :workspace_source, OwnedSource)

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

  test "connect emits one final allowlisted auth decision and assigns validated timing" do
    generation = generation()
    token = ChannelAuth.sign_user_token("private-user", "private@example.com")
    attach_feed_telemetry(self())

    assert {:ok, socket} =
             UserSocket.connect(
               %{
                 "token" => token,
                 "connection_generation" => generation,
                 "connection_cycle" => "cold"
               },
               %Phoenix.Socket{},
               %{}
             )

    assert %FeedTiming{} = socket.assigns.mobile_feed_timing

    assert FeedTiming.wire_context(socket.assigns.mobile_feed_timing) == %{
             connection_generation: generation,
             connection_cycle: "cold"
           }

    assert_receive {:feed_auth, measurements,
                    %{
                      stage: :token_verified,
                      outcome: :succeeded,
                      reason_code: :user_token,
                      connection_generation: ^generation
                    } = metadata}

    refute_receive {:feed_auth, _measurements, _metadata}, 50

    serialized = inspect({measurements, metadata})
    refute serialized =~ token
    refute serialized =~ "private-user"
    refute serialized =~ "private@example.com"
  end

  test "connect emits only the final failure after all verifier fallbacks" do
    generation = generation()
    token = "invalid-private-token"
    attach_feed_telemetry(self())

    assert :error =
             UserSocket.connect(
               %{
                 "token" => token,
                 "connection_generation" => generation,
                 "connection_cycle" => "reconnect"
               },
               %Phoenix.Socket{},
               %{}
             )

    assert_receive {:feed_auth, measurements,
                    %{
                      stage: :token_verified,
                      outcome: :failed,
                      reason_code: :invalid_token,
                      connection_generation: ^generation
                    } = metadata}

    refute_receive {:feed_auth, _measurements, _metadata}, 50
    refute inspect({measurements, metadata}) =~ token
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

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  defp attach_feed_telemetry(test_pid) do
    handler = {__MODULE__, test_pid, System.unique_integer([:positive])}

    :telemetry.attach(
      handler,
      [:casein, :mobile, :feed, :stage],
      fn _event, measurements, metadata, pid ->
        if metadata.stage == :token_verified do
          send(pid, {:feed_auth, measurements, metadata})
        end
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp generation do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
